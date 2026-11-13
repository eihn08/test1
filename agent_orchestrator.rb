# encoding: utf-8
# frozen_string_literal: true

require 'time'
require 'securerandom'
require_relative 'llm_client'
require_relative 'rfp_extractor'
require_relative 'feasibility_matcher'
require_relative 'pricing_engine'
require_relative 'proposal_builder'

module ThienMinh
  class AgentOrchestrator
    def initialize(store)
      @store = store
      seed_initial_cases_if_needed!
    end

    def seed_initial_cases_if_needed!
      return if @store.seeded?

      samples = @store.sample_rfps
      samples.each do |s|
        rec = build_new_case_record(
          id: s['id'],
          title: s['title'],
          raw_text: s['raw_text'],
          channel: s['channel'],
          sales_owner: s['sales_owner'],
          received_date: s['received_date'],
          expected_scenario: s['expected_scenario']
        )
        @store.save_case(rec)
        run_pipeline(rec['id'])
      end
      @store.mark_seeded!
    end

    def create_case(params)
      id = params['id'] || "RFP-2026-#{rand(2000..9999)}"
      rec = build_new_case_record(
        id: id,
        title: params['title'].to_s.strip.empty? ? "Yêu cầu chào giá #{id}" : params['title'].to_s.strip,
        raw_text: params['raw_text'].to_s,
        channel: params['channel'] || 'Nhập trực tiếp',
        sales_owner: params['sales_owner'] || 'Nhân viên Kinh doanh',
        received_date: Time.now.strftime('%Y-%m-%d'),
        expected_scenario: 'Hồ sơ mới tạo'
      )
      @store.save_case(rec)
      run_pipeline(rec['id'])
    end

    def run_pipeline(case_id, override_discount_pct: nil)
      rec = @store.find_case(case_id)
      raise "Không tìm thấy hồ sơ #{case_id}" unless rec

      settings = @store.settings
      llm = LLMClient.new(settings)
      extractor = RfpExtractor.new(llm)
      matcher = FeasibilityMatcher.new(@store)
      pricing_engine = PricingEngine.new(@store)
      proposal_builder = ProposalBuilder.new(@store)

      trace = []
      now = Time.now.iso8601

      # Step 1: Receive (Lark Base / Portal)
      trace << {
        'step' => 'RECEIVE',
        'label' => 'BẮT ĐẦU: Tiếp nhận hồ sơ RFP/RFQ (Lark Base)',
        'actor' => 'Hệ thống Lark Base / Kinh doanh',
        'status' => 'DONE',
        'timestamp' => now,
        'summary' => "Đã tiếp nhận hồ sơ từ #{rec['channel']} (Phụ trách: #{rec['sales_owner']})."
      }

      # Combine raw text + any customer clarifications
      full_text = rec['raw_text'].to_s
      if rec['clarifications'] && !rec['clarifications'].empty?
        supp_block = rec['clarifications'].map.with_index(1) do |c, i|
          "\n[Bổ sung từ Khách hàng lần #{i} - #{c['timestamp']}]:\n#{c['customer_reply']}"
        end.join("\n")
        full_text = "#{full_text}\n#{supp_block}"
      end

      # Step 2: Skill 1 - AI Agent Extract & Decompose
      ext_res = extractor.extract_and_check(full_text, rec['title'])
      extracted = ext_res['extracted']
      gate = ext_res['completeness_gate']

      trace << {
        'step' => 'SKILL_1',
        'label' => 'KỸ NĂNG 1 - AI AGENT: Bóc tách & Phân tích hồ sơ',
        'actor' => ext_res['used_llm'] ? "AI Agent (#{settings['provider'].upcase})" : 'AI Agent (Offline Engine)',
        'status' => 'DONE',
        'timestamp' => Time.now.iso8601,
        'summary' => "Bóc tách được #{(extracted['items'] || []).size} hạng mục, #{(extracted['mandatory_conditions'] || []).size} điều kiện bắt buộc, deadline: #{extracted.dig('deadline', 'raw_text') || 'Chưa rõ'}, ngân sách: #{extracted.dig('budget', 'amount_vnd') ? format_vnd(extracted.dig('budget', 'amount_vnd')) : 'Chưa rõ'}."
      }

      # Step 3: Gate 1 - Completeness Check
      if !gate['is_complete']
        trace << {
          'step' => 'GATE_1',
          'label' => 'Cổng 1: Có đủ dữ liệu hợp lệ?',
          'actor' => 'AI Agent Gatekeeper',
          'status' => 'BLOCKED',
          'decision' => 'KHÔNG',
          'timestamp' => Time.now.iso8601,
          'summary' => "Phát hiện #{gate['blocking_count']} thiếu sót bắt buộc (Điểm: #{gate['completeness_score']}/100). Kích hoạt nhánh HITL Kinh doanh liên hệ khách hàng."
        }
        trace << {
          'step' => 'HITL_SALES',
          'label' => 'HITL: Kinh doanh liên hệ khách hàng (Yêu cầu bổ sung thông tin)',
          'actor' => rec['sales_owner'],
          'status' => 'ACTIVE',
          'timestamp' => Time.now.iso8601,
          'summary' => 'Đã soạn sẵn thư yêu cầu xác nhận thông tin thiếu để gửi khách hàng.'
        }

        rec['extracted'] = extracted
        rec['completeness_gate'] = gate
        rec['feasibility'] = nil
        rec['pricing'] = nil
        rec['deliverables'] = nil
        rec['status'] = 'NEEDS_CLARIFICATION'
        rec['triage_category'] = 'CẦN XÁC MINH / BỔ SUNG THÔNG TIN'
        rec['current_node'] = 'HITL_SALES'
        rec['step_progress'] = { 'current_step' => 1, 'max_unlocked_step' => 1 }
        rec['workflow_trace'] = trace
        add_audit(rec, 'AI_RUN', 'AI Agent tạm dừng tại Cổng 1: Thiếu dữ liệu bắt buộc.')
        return @store.save_case(rec)
      end

      trace << {
        'step' => 'GATE_1',
        'label' => 'Cổng 1: Có đủ dữ liệu hợp lệ?',
        'actor' => 'AI Agent Gatekeeper',
        'status' => 'DONE',
        'decision' => 'CÓ',
        'timestamp' => Time.now.iso8601,
        'summary' => "Dữ liệu hợp lệ (#{gate['completeness_score']}/100 điểm). Chuyển tiếp sang Kỹ năng 2: Thẩm định Kỹ thuật."
      }

      # Step 4: Skill 2 - AI Agent Technical Feasibility
      feasibility = matcher.match(extracted)
      traps_count = (feasibility['rejected_low_price_traps'] || []).size
      has_out = feasibility['has_out_of_catalog']
      sched_ok = feasibility.dig('schedule_check', 'feasible')

      trace << {
        'step' => 'SKILL_2',
        'label' => 'KỸ NĂNG 2 - AI AGENT: Thẩm định Kỹ thuật',
        'actor' => 'AI Agent Technical Matcher',
        'status' => has_out ? 'WARNING' : 'DONE',
        'timestamp' => Time.now.iso8601,
        'summary' => "Đối chiếu danh mục: Khớp #{(feasibility['matched_items'] || []).size} hạng mục; chặn #{traps_count} bẫy giá thấp thiếu tính năng; thiết bị ngoài danh mục: #{has_out ? 'CÓ' : 'Không'}."
      }

      # Step 5: Gate 2 - Technical Gate
      existing_survey = (rec['hitl'] && rec['hitl']['tech_survey']) || {}
      if has_out
        trace << {
          'step' => 'GATE_2',
          'label' => 'Cổng 2: Kỹ thuật có đáp ứng?',
          'actor' => 'AI Agent Gatekeeper',
          'status' => existing_survey['conducted'] ? 'DONE' : 'WARNING',
          'decision' => 'Ngoài danh mục / Cần xác nhận',
          'timestamp' => Time.now.iso8601,
          'summary' => "Phát hiện thiết bị đặc thù ngoài danh mục chuẩn (#{(feasibility['out_of_catalog_items'] || []).map { |x| x['requested_name'] }.join(', ')}). Cần Kỹ thuật & Vận hành khảo sát phương án."
        }
        trace << {
          'step' => 'HITL_TECH_SURVEY',
          'label' => 'HITL: Kỹ thuật & Vận hành khảo sát (Đánh giá phương án đặc thù)',
          'actor' => 'Kỹ sư Pre-sales & PMO Vận hành',
          'status' => existing_survey['conducted'] ? 'DONE' : 'ACTIVE',
          'timestamp' => Time.now.iso8601,
          'summary' => existing_survey['conducted'] ? "Đã hoàn tất khảo sát: #{existing_survey['decision']} (Bởi #{existing_survey['by']})." : 'Cần xác nhận khả năng sourcing NCC Moxa/Hirschmann và tính tương thích.'
        }
      else
        trace << {
          'step' => 'GATE_2',
          'label' => 'Cổng 2: Kỹ thuật có đáp ứng?',
          'actor' => 'AI Agent Gatekeeper',
          'status' => 'DONE',
          'decision' => 'Có / Đáp ứng',
          'timestamp' => Time.now.iso8601,
          'summary' => '100% thiết bị chuẩn danh mục Thiên Minh, không phát hiện rủi ro thiếu tính năng.'
        }
      end

      # Step 6: Skill 3 - AI Agent Deployment & Pricing Engine
      if override_discount_pct
        extracted['requested_discount_pct'] = override_discount_pct.to_f
      end
      pricing = pricing_engine.calculate(extracted, feasibility)

      trace << {
        'step' => 'SKILL_3',
        'label' => 'KỸ NĂNG 3 - AI AGENT: Thẩm định Triển khai & Giá',
        'actor' => 'AI Agent Operations & Pricing Engine',
        'status' => sched_ok ? 'DONE' : 'WARNING',
        'timestamp' => Time.now.iso8601,
        'summary' => "Lịch nhân sự: #{sched_ok ? 'Khả thi' : 'Cảnh báo trùng lịch'}; Đơn giá trước VAT: #{format_vnd(pricing['net_before_vat_vnd'])} (CK #{pricing['proposed_discount_pct']}%, Biên LN #{pricing['gross_margin_pct']}%)."
      }

      # Step 7: Consolidate Deliverables (Matrix + Quote + Tasklist)
      deliverables = proposal_builder.build(
        case_id: rec['id'],
        extracted: extracted,
        feasibility: feasibility,
        pricing: pricing,
        revision_notes: rec['revision_notes'] || []
      )

      trace << {
        'step' => 'CONSOLIDATE',
        'label' => 'HỢP NHẤT BÁO CÁO & TÀI LIỆU',
        'actor' => 'AI Agent Consolidator',
        'status' => 'DONE',
        'timestamp' => Time.now.iso8601,
        'summary' => "Hợp nhất Ma trận đáp ứng (#{deliverables['compliance_matrix'].size} dòng), Tasklist phối hợp 3 phòng ban (#{deliverables['tasklist_coordination'].size} tác vụ) & Dự thảo chào giá #{deliverables.dig('draft_quotation', 'quote_number')}."
      }

      # Step 8: Gate 3 - Authority & Escalation Gate
      auth = pricing['authority_gate'] || {}
      needs_esc = auth['needs_escalation'] || (has_out && !existing_survey['conducted']) || !sched_ok

      trace << {
        'step' => 'GATE_3',
        'label' => 'Cổng 3: Có điều kiện Cần xác nhận hoặc Vượt thẩm quyền?',
        'actor' => 'AI Agent Policy Gate',
        'status' => needs_esc ? 'ESCALATED' : 'DONE',
        'decision' => needs_esc ? 'CÓ' : 'KHÔNG',
        'timestamp' => Time.now.iso8601,
        'summary' => needs_esc ?
          "Kích hoạt HITL Phê duyệt & Điều phối (#{auth['highest_authority_level'] || 'Quản lý 3 bên'}): #{(auth['triggers'] || []).map { |t| t['code'] }.join(', ')} #{has_out ? '+ Thiết bị ngoài DM' : ''} #{!sched_ok ? '+ Trùng lịch' : ''}." :
          'Trong thẩm quyền chuẩn — đủ điều kiện chuyển duyệt xuất bản.'
      }

      rec['extracted'] = extracted
      rec['completeness_gate'] = gate
      rec['feasibility'] = feasibility
      rec['pricing'] = pricing
      rec['deliverables'] = deliverables
      rec['workflow_trace'] = trace

      rec['hitl'] ||= {}
      rec['hitl']['tech_survey'] ||= existing_survey
      rec['hitl']['escalation_approved'] = !auth['needs_escalation']
      rec['hitl']['escalation_approver'] = nil
      rec['hitl']['escalation_comment'] = nil
      rec['hitl']['dept_signoffs'] ||= {
        'sales' => { 'approved' => false, 'by' => nil, 'at' => nil, 'note' => nil },
        'technical' => { 'approved' => false, 'by' => nil, 'at' => nil, 'note' => nil },
        'operations' => { 'approved' => false, 'by' => nil, 'at' => nil, 'note' => nil }
      }

      rec['step_progress'] = {
        'current_step' => needs_esc ? 5 : 4,
        'max_unlocked_step' => 5
      }

      if needs_esc
        rec['status'] = 'PENDING_ESCALATION'
        rec['triage_category'] = 'CẦN CHUYỂN DUYỆT (VƯỢT THẨM QUYỀN / RỦI RO)'
        rec['current_node'] = 'HITL_APPROVAL'
      else
        rec['status'] = 'READY_FOR_HITL_REVIEW'
        rec['triage_category'] = 'SẴN SÀNG CHUẨN BỊ CHÀO GIÁ'
        rec['current_node'] = 'HITL_APPROVAL'
      end

      add_audit(rec, 'AI_RUN', "AI Agent hoàn tất phân tích 3 Kỹ năng & Hợp nhất tài liệu. Trạng thái: #{rec['triage_category']}.")
      @store.save_case(rec)
    end

    def submit_clarification(case_id, customer_reply, actor = 'Nhân viên Kinh doanh')
      rec = @store.find_case(case_id)
      raise "Không tìm thấy hồ sơ #{case_id}" unless rec

      rec['clarifications'] ||= []
      rec['clarifications'] << {
        'timestamp' => Time.now.iso8601,
        'actor' => actor,
        'customer_reply' => customer_reply.to_s.strip
      }
      add_audit(rec, 'CLARIFICATION_ADDED', "#{actor} đã cập nhật thông tin bổ sung từ khách hàng và đưa hồ sơ vào xử lý lại.")
      @store.save_case(rec)
      run_pipeline(case_id)
    end

    def survey_tech_signoff(case_id, surveyor_name, decision, notes = '')
      rec = @store.find_case(case_id)
      raise "Không tìm thấy hồ sơ #{case_id}" unless rec

      rec['hitl'] ||= {}
      rec['hitl']['tech_survey'] = {
        'conducted' => true,
        'by' => surveyor_name.to_s.strip.empty? ? 'Kỹ sư Pre-sales & PMO' : surveyor_name.to_s.strip,
        'at' => Time.now.iso8601,
        'decision' => decision || 'CHẤP THUẬN PHƯƠNG ÁN ĐẶC THÙ',
        'notes' => notes.to_s.strip.empty? ? 'Đã khảo sát hiện trường, xác nhận NCC phụ và tương thích kỹ thuật.' : notes.to_s.strip
      }
      add_audit(rec, 'TECH_SURVEY_COMPLETED', "#{surveyor_name} (Kỹ thuật & Vận hành) đã hoàn tất khảo sát: #{decision} - #{notes}")
      @store.save_case(rec)
      run_pipeline(case_id)
    end

    def approve_escalation(case_id, approver_name, role, decision, comment, adjusted_discount_pct = nil)
      rec = @store.find_case(case_id)
      raise "Không tìm thấy hồ sơ #{case_id}" unless rec

      if adjusted_discount_pct && !adjusted_discount_pct.to_s.strip.empty?
        # Re-run pricing with manager-adjusted discount first if requested
        run_pipeline(case_id, override_discount_pct: adjusted_discount_pct.to_f)
        rec = @store.find_case(case_id)
      end

      rec['hitl'] ||= {}
      if decision == 'APPROVE'
        rec['hitl']['escalation_approved'] = true
        rec['hitl']['escalation_approver'] = "#{approver_name} (#{role})"
        rec['hitl']['escalation_comment'] = comment
        rec['hitl']['escalation_at'] = Time.now.iso8601

        rec['status'] = 'READY_FOR_HITL_REVIEW'
        rec['triage_category'] = 'ĐÃ DUYỆT CẤP TRÊN — CHỜ THẨM ĐỊNH CUỐI'
        rec['current_node'] = 'HITL_FINAL_REVIEW'
        add_audit(rec, 'ESCALATION_APPROVED', "#{approver_name} (#{role}) đã PHÊ DUYỆT chuyển cấp. Ghi chú: #{comment}")
      else
        rec['hitl']['escalation_approved'] = false
        rec['revision_notes'] ||= []
        rec['revision_notes'] << { 'at' => Time.now.iso8601, 'by' => "#{approver_name} (#{role})", 'note' => comment }
        rec['status'] = 'REVISION_REQUESTED'
        rec['triage_category'] = 'CẦN CHỈNH SỬA / THƯƠNG THẢO LẠI'
        rec['current_node'] = 'EXTRACT'
        add_audit(rec, 'ESCALATION_REJECTED', "#{approver_name} (#{role}) yêu cầu chỉnh sửa/từ chối vượt cấp: #{comment}")
      end

      @store.save_case(rec)
    end

    def submit_dept_signoff(case_id, dept, reviewer_name, action, note = '')
      rec = @store.find_case(case_id)
      raise "Không tìm thấy hồ sơ #{case_id}" unless rec
      raise "Phòng ban không hợp lệ: #{dept}" unless %w[sales technical operations].include?(dept)

      rec['hitl'] ||= {}
      rec['hitl']['dept_signoffs'] ||= {}

      if action == 'REQUEST_REVISION'
        rec['revision_notes'] ||= []
        rec['revision_notes'] << { 'at' => Time.now.iso8601, 'by' => "#{reviewer_name} (#{dept_label(dept)})", 'note' => note }
        rec['status'] = 'REVISION_REQUESTED'
        rec['triage_category'] = 'CẦN CHỈNH SỬA THEO HITL'
        rec['current_node'] = 'EXTRACT'
        add_audit(rec, 'HITL_REVISION', "#{reviewer_name} (#{dept_label(dept)}) chọn 'Cần chỉnh sửa': #{note}")
        return @store.save_case(rec)
      end

      rec['hitl']['dept_signoffs'][dept] = {
        'approved' => true,
        'by' => reviewer_name,
        'at' => Time.now.iso8601,
        'note' => note
      }
      add_audit(rec, 'DEPT_SIGNOFF', "#{dept_label(dept)} (#{reviewer_name}) đã xác nhận thẩm định & kiểm tra ranh giới dữ liệu.")

      @store.save_case(rec)
    end

    def publish_quotation(case_id, publisher_name)
      rec = @store.find_case(case_id)
      raise "Không tìm thấy hồ sơ #{case_id}" unless rec

      hitl = rec['hitl'] || {}
      unless hitl['escalation_approved']
        raise 'Hồ sơ chưa được Trưởng phòng / Ban Giám đốc phê duyệt chuyển cấp!'
      end

      signoffs = hitl['dept_signoffs'] || {}
      missing_depts = %w[sales technical operations].reject { |d| signoffs.dig(d, 'approved') }
      unless missing_depts.empty?
        labels = missing_depts.map { |d| dept_label(d) }.join(', ')
        raise "Cần đủ 3 bộ phận duyệt cuối trước khi xuất bản! Còn thiếu: #{labels}."
      end

      rec['status'] = 'PUBLISHED'
      rec['triage_category'] = 'ĐÃ XUẤT BẢN CHÀO GIÁ'
      rec['current_node'] = 'PUBLISHED'
      rec['published_at'] = Time.now.iso8601
      rec['published_by'] = publisher_name
      add_audit(rec, 'PUBLISHED', "Đã xuất bản bản chào giá chính thức & sẵn sàng gửi khách hàng (Người phát hành: #{publisher_name}).")
      @store.save_case(rec)
    end

    def dashboard_summary
      cases = @store.all_cases
      {
        'total' => cases.size,
        'ready_for_quote' => cases.count { |c| %w[READY_FOR_HITL_REVIEW PUBLISHED].include?(c['status']) },
        'needs_clarification' => cases.count { |c| c['status'] == 'NEEDS_CLARIFICATION' },
        'pending_escalation' => cases.count { |c| %w[PENDING_ESCALATION REVISION_REQUESTED].include?(c['status']) },
        'published' => cases.count { |c| c['status'] == 'PUBLISHED' },
        'total_pipeline_vnd' => cases.sum { |c| c.dig('pricing', 'net_before_vat_vnd').to_i },
        'traps_prevented' => cases.sum { |c| (c.dig('feasibility', 'rejected_low_price_traps') || []).size }
      }
    end

    private

    def build_new_case_record(id:, title:, raw_text:, channel:, sales_owner:, received_date:, expected_scenario:)
      {
        'id' => id,
        'title' => title,
        'raw_text' => raw_text,
        'channel' => channel,
        'sales_owner' => sales_owner,
        'received_date' => received_date,
        'expected_scenario' => expected_scenario,
        'status' => 'NEW',
        'triage_category' => 'MỚI TIẾP NHẬN',
        'current_node' => 'RECEIVE',
        'clarifications' => [],
        'revision_notes' => [],
        'audit_log' => [
          {
            'at' => Time.now.iso8601,
            'type' => 'CREATED',
            'message' => "Tiếp nhận yêu cầu chào giá #{id} qua #{channel}."
          }
        ]
      }
    end

    def add_audit(rec, type, message)
      rec['audit_log'] ||= []
      rec['audit_log'] << {
        'at' => Time.now.iso8601,
        'type' => type,
        'message' => message
      }
    end

    def dept_label(dept)
      case dept
      when 'sales' then 'Kinh doanh'
      when 'technical' then 'Kỹ thuật'
      when 'operations' then 'Vận hành'
      else dept
      end
    end

    def format_vnd(num)
      s = num.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1.').reverse
      "#{s} VND"
    end
  end
end

