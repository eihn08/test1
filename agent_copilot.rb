# encoding: utf-8
# frozen_string_literal: true

require 'json'
require_relative 'llm_client'

module ThienMinh
  class AgentCopilot
    def initialize(store)
      @store = store
    end

    def reply(message:, case_id: nil)
      msg = message.to_s.strip
      cases = @store.all_cases
      selected = case_id ? cases.find { |c| c['id'] == case_id } : nil
      mentioned = find_mentioned_case(msg, cases) || selected

      llm = LLMClient.new(@store.settings)
      if llm.llm_enabled?
        llm_answer = try_llm_chat(llm, msg, cases, mentioned)
        return llm_answer if llm_answer
      end

      offline_reply(msg, cases, mentioned)
    end

    private

    def find_mentioned_case(msg, cases)
      norm = msg.downcase
      cases.find do |c|
        id_short = c['id'].to_s.downcase.split('-').last
        cust = c.dig('extracted', 'customer_name').to_s.downcase
        title = c['title'].to_s.downcase
        norm.include?(c['id'].downcase) ||
          (id_short && norm.include?(id_short)) ||
          (!cust.empty? && cust.split.any? { |w| w.length > 3 && norm.include?(w) }) ||
          (norm.include?('đông nam') && title.include?('đông nam')) ||
          (norm.include?('tâm an') && title.include?('tâm an')) ||
          (norm.include?('an phát') && title.include?('an phát')) ||
          (norm.include?('fintech') && title.include?('fintech')) ||
          (norm.include?('sunmart') && title.include?('sunmart')) ||
          (norm.include?('hòa bình') && title.include?('hòa bình'))
      end
    end

    def try_llm_chat(llm, msg, cases, target_case)
      compact_cases = cases.map do |c|
        {
          'id' => c['id'],
          'title' => c['title'],
          'status' => c['status'],
          'triage' => c['triage_category'],
          'customer' => c.dig('extracted', 'customer_name'),
          'completeness' => c.dig('completeness_gate', 'completeness_score'),
          'net_vnd' => c.dig('pricing', 'net_before_vat_vnd'),
          'discount_pct' => c.dig('pricing', 'proposed_discount_pct'),
          'traps_blocked' => (c.dig('feasibility', 'rejected_low_price_traps') || []).size,
          'schedule_feasible' => c.dig('feasibility', 'schedule_check', 'feasible'),
          'escalation_triggers' => (c.dig('pricing', 'authority_gate', 'triggers') || []).map { |t| t['reason'] }
        }
      end

      context = {
        'cases_summary' => compact_cases,
        'focused_case' => target_case ? {
          'id' => target_case['id'],
          'completeness_gate' => target_case['completeness_gate'],
          'feasibility' => target_case['feasibility'],
          'pricing' => target_case['pricing']
        } : nil,
        'weekly_schedule' => @store.capacity_schedule['weekly_schedule']
      }

      system_prompt = <<~PROMPT
        Bạn là Trợ lý AI Agent nội bộ của Công ty Thiên Minh (cung cấp thiết bị mạng & dịch vụ triển khai).
        Hãy trả lời ngắn gọn, dễ hiểu, chính xác theo dữ liệu JSON được cung cấp dưới đây. Tuyệt đối không bịa giá hay số liệu ngoài dữ liệu này.
        Trả về JSON dạng: { "answer": "câu trả lời tiếng Việt rõ ràng", "suggested_case_id": "RFP-... hoặc null", "suggested_tab": "extract|feasibility|pricing|proposal|null" }
      PROMPT

      user_prompt = "Câu hỏi người dùng: #{msg}\n\nDữ liệu hệ thống hiện tại:\n#{JSON.generate(context)}"
      res = llm.generate_json(system_prompt, user_prompt)
      return nil unless res['ok'] && res['data'].is_a?(Hash) && res['data']['answer']

      {
        'ok' => true,
        'engine' => "LLM (#{llm.provider.upcase})",
        'answer' => res['data']['answer'],
        'suggested_case_id' => res['data']['suggested_case_id'],
        'suggested_tab' => res['data']['suggested_tab'],
        'quick_prompts' => default_prompts
      }
    rescue StandardError
      nil
    end

    def offline_reply(msg, cases, target_case)
      norm = msg.downcase

      # 1. Questions about triage / which RFPs are ready vs blocked
      if norm.include?('hồ sơ nào') || norm.include?('tổng quan') || norm.include?('chào giá ngay') || norm.include?('sẵn sàng') || norm.include?('cần xác minh')
        ready = cases.select { |c| %w[READY_FOR_HITL_REVIEW PUBLISHED].include?(c['status']) }
        clarify = cases.select { |c| c['status'] == 'NEEDS_CLARIFICATION' }
        esc = cases.select { |c| %w[PENDING_ESCALATION REVISION_REQUESTED].include?(c['status']) }

        lines = []
        lines << "📊 **Phân loại #{cases.size} hồ sơ RFP hiện tại của Thiên Minh:**"
        lines << "• 🟢 **Có thể chuẩn bị chào giá ngay (#{ready.size}):** #{ready.map { |c| "#{c['id']} (#{c.dig('extracted', 'customer_name')})" }.join(', ')}."
        lines << "• 🟡 **Phải xác minh / hỏi thêm KH trước (#{clarify.size}):** #{clarify.map { |c| "#{c['id']} — thiếu #{c.dig('completeness_gate', 'blocking_count')} thông số" }.join(', ')}." unless clarify.empty?
        lines << "• 🟠 **Phải chuyển duyệt vượt thẩm quyền / xử lý rủi ro (#{esc.size}):** #{esc.map { |c| "#{c['id']} (#{c.dig('pricing', 'authority_gate', 'highest_authority_level')})" }.join(', ')}." unless esc.empty?

        return build_response(lines.join("\n"), ready.first && ready.first['id'], 'proposal')
      end

      # 2. Questions about schedule & engineering capacity
      if norm.include?('lịch') || norm.include?('tuần') || norm.include?('rảnh') || norm.include?('quá tải') || norm.include?('năng lực')
        weeks = @store.capacity_schedule['weekly_schedule'] || []
        busy = weeks.select { |w| w['utilization_pct'] >= 85 }.map { |w| "#{w['week_id']} (#{w['utilization_pct']}%)" }
        free = weeks.select { |w| w['status'] == 'AVAILABLE' }.map { |w| "#{w['label']} — còn #{w['available_man_days']} ngày công" }
        ans = [
          '🗓 **Tình hình năng lực & lịch triển khai Vận hành:**',
          "• Tuần đang quá tải/sát trần: #{busy.join(', ')}.",
          "• Các tuần khả dụng nhận dự án mới:\n  - #{free.join("\n  - ")}",
          target_case && target_case.dig('feasibility', 'schedule_check') ? "• Với hồ sơ **#{target_case['id']}**: #{target_case.dig('feasibility', 'schedule_check', 'recommendation')}" : nil
        ].compact.join("\n")
        return build_response(ans, target_case && target_case['id'], 'feasibility')
      end

      # 3. Questions about low-price traps
      if norm.include?('bẫy') || norm.include?('giá thấp') || norm.include?('giá rẻ') || norm.include?('loại')
        cases_with_traps = cases.select { |c| (c.dig('feasibility', 'rejected_low_price_traps') || []).any? }
        total_traps = cases_with_traps.sum { |c| c.dig('feasibility', 'rejected_low_price_traps').size }
        focus = target_case && (target_case.dig('feasibility', 'rejected_low_price_traps') || []).any? ? target_case : cases_with_traps.first
        if focus
          traps = focus.dig('feasibility', 'rejected_low_price_traps') || []
          details = traps.map { |t| "  - Loại **#{t['rejected_sku']}** (#{format_vnd(t['rejected_unit_price_vnd'])}) cho *#{t['requested_item']}* vì: #{t['failed_reasons'].join('; ')}." }.join("\n")
          ans = "🛡️ **AI Agent đã tự động chặn #{total_traps} gói giá thấp sai chức năng trên toàn hệ thống.**\nVí dụ tại **#{focus['id']}**:\n#{details}"
          return build_response(ans, focus['id'], 'feasibility')
        end
      end

      # 4. Questions about a specific case
      if target_case
        c = target_case
        comp = c['completeness_gate'] || {}
        if c['status'] == 'NEEDS_CLARIFICATION'
          missing_list = (comp['missing_fields'] || []).first(4).map { |m| "  - **#{m['field']}**: #{m['question_for_customer']}" }.join("\n")
          ans = "🟡 **Hồ sơ #{c['id']} (#{c.dig('extracted', 'customer_name')})** đang dừng ở cổng kiểm tra thông tin (#{comp['completeness_score']}/100 điểm).\n**Các phần Kinh doanh cần hỏi lại KH trước khi chào giá:**\n#{missing_list}"
          return build_response(ans, c['id'], 'extract')
        end

        p = c['pricing'] || {}
        auth = p['authority_gate'] || {}
        sched = c.dig('feasibility', 'schedule_check') || {}
        traps_n = (c.dig('feasibility', 'rejected_low_price_traps') || []).size
        triggers = (auth['triggers'] || []).map { |t| "  - **[#{t['code']}]** #{t['reason']} *(Người duyệt: #{t['approver']})*" }.join("\n")

        ans = [
          "🤖 **Tóm tắt phân tích AI Agent cho #{c['id']} — #{c.dig('extracted', 'customer_name')}:**",
          "• **Trạng thái:** #{c['triage_category']}",
          "• **Giá đề xuất (trước VAT):** #{format_vnd(p['net_before_vat_vnd'])} (Chiết khấu #{p['proposed_discount_pct']}%, Biên LN #{p['gross_margin_pct']}%)",
          "• **Bẫy giá thấp đã chặn:** #{traps_n} cấu hình không đạt thông số bắt buộc",
          "• **Lịch triển khai:** #{sched['feasible'] ? '✅ Khả thi' : '🚨 Xung đột'} — #{sched['recommendation']}",
          auth['needs_escalation'] ? "• **Lý do phải chuyển duyệt (#{auth['highest_authority_level']}):**\n#{triggers}" : '• **Thẩm quyền:** ✅ Đạt chuẩn, không cần chuyển duyệt vượt cấp.'
        ].join("\n")
        return build_response(ans, c['id'], auth['needs_escalation'] ? 'pricing' : 'proposal')
      end

      # 5. Fallback / General guidance
      ans = [
        'Xin chào! Tôi là **Trợ lý AI Agent Thiên Minh**. Bạn có thể hỏi tôi về:',
        '• *"Hồ sơ nào có thể chào giá ngay hôm nay?"*',
        '• *"Phân tích rủi ro của Fintech An Phát hoặc SunMart"*',
        '• *"Tại sao AI lại chặn các gói giá thấp?"*',
        '• *"Tuần nào đội Kỹ thuật còn lịch trống?"*'
      ].join("\n")
      build_response(ans, nil, nil)
    end

    def build_response(answer, case_id, tab)
      {
        'ok' => true,
        'engine' => 'Thiên Minh AI Agent (Grounded)',
        'answer' => answer,
        'suggested_case_id' => case_id,
        'suggested_tab' => tab,
        'quick_prompts' => default_prompts
      }
    end

    def default_prompts
      [
        'Hồ sơ nào chào giá được ngay?',
        'Tại sao SunMart cần Ban Giám đốc duyệt?',
        'Fintech An Phát vướng lịch thế nào?',
        'Tuần nào đội Kỹ thuật rảnh nhất?'
      ]
    end

    def format_vnd(num)
      return '0 đ' if num.nil?

      s = num.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1.').reverse
      "#{s} đ"
    end
  end
end

