# encoding: utf-8
# frozen_string_literal: true

module ThienMinh
  class PricingEngine
    def initialize(store)
      @store = store
    end

    def calculate(extracted, feasibility)
      policies = @store.policies
      matched_items = feasibility['matched_items'] || []
      vat_rate = (policies['vat_rate_pct'] || 10).to_f

      line_items = matched_items.map do |m|
        qty = (m['quantity'] || 1).to_i
        unit_price = (m['unit_price_vnd'] || 0).to_f
        unit_cost = (m['cost_vnd'] || 0).to_f
        is_service = ['Deployment Service', 'Maintenance & SLA'].include?(m['category'])

        {
          'item_id' => m['item_id'],
          'sku' => m['selected_sku'],
          'name' => m['selected_name'],
          'category' => m['category'],
          'is_service' => is_service,
          'status' => m['status'],
          'unit' => m['unit'],
          'quantity' => qty,
          'unit_price_vnd' => unit_price.round,
          'line_list_total_vnd' => (unit_price * qty).round,
          'line_cost_total_vnd' => (unit_cost * qty).round
        }
      end

      list_subtotal = line_items.sum { |l| l['line_list_total_vnd'] }
      total_cost = line_items.sum { |l| l['line_cost_total_vnd'] }

      # Find matching standard discount tier
      tiers = policies['discount_tiers'] || []
      tier = tiers.find { |t| list_subtotal >= t['min_amount_vnd'] && list_subtotal <= t['max_amount_vnd'] } || tiers.first

      hw_list = line_items.reject { |l| l['is_service'] }.sum { |l| l['line_list_total_vnd'] }
      srv_list = line_items.select { |l| l['is_service'] }.sum { |l| l['line_list_total_vnd'] }

      std_hw_disc_pct = (tier ? tier['standard_hardware_discount_pct'] : 2.0).to_f
      std_srv_disc_pct = (tier ? tier['standard_service_discount_pct'] : 3.0).to_f
      std_discount_vnd = ((hw_list * std_hw_disc_pct / 100.0) + (srv_list * std_srv_disc_pct / 100.0)).round
      std_overall_pct = list_subtotal > 0 ? ((std_discount_vnd.to_f / list_subtotal) * 100.0).round(2) : 0.0

      budget_vnd = extracted.dig('budget', 'amount_vnd')
      requested_disc_pct = extracted['requested_discount_pct']

      # Determine proposed discount
      proposed_disc_pct = std_overall_pct
      discount_reason = "Áp dụng chiết khấu chuẩn theo #{tier ? tier['name'] : 'bảng giá'}."

      if requested_disc_pct && requested_disc_pct.to_f > std_overall_pct
        proposed_disc_pct = requested_disc_pct.to_f
        discount_reason = "Khách hàng yêu cầu chiết khấu đặc biệt #{proposed_disc_pct}% (vượt mức chuẩn #{std_overall_pct}%)."
      elsif budget_vnd && budget_vnd.to_f > 0
        std_net = list_subtotal - std_discount_vnd
        if std_net > budget_vnd.to_f
          needed_pct = (((list_subtotal - budget_vnd.to_f) / list_subtotal.to_f) * 100.0).round(2)
          if needed_pct <= 12.0
            proposed_disc_pct = [needed_pct, std_overall_pct].max
            discount_reason = "Đề xuất chiết khấu #{proposed_disc_pct}% (tăng từ #{std_overall_pct}%) để khớp ngân sách khách hàng (#{format_vnd(budget_vnd)})."
          else
            # Cannot cut below safe executive floor just to chase unrealistic budget
            proposed_disc_pct = [std_overall_pct, 8.0].max
            discount_reason = "Ngân sách khách hàng (#{format_vnd(budget_vnd)}) thấp hơn giá vốn/biên tối thiểu (cần giảm #{needed_pct}%). Đề xuất mức chiết khấu tối đa #{proposed_disc_pct}% và khuyến nghị thương thảo ngân sách hoặc phân kỳ."
          end
        end
      end

      discount_amount_vnd = (list_subtotal * proposed_disc_pct / 100.0).round
      net_before_vat_vnd = list_subtotal - discount_amount_vnd
      vat_amount_vnd = (net_before_vat_vnd * vat_rate / 100.0).round
      grand_total_vnd = net_before_vat_vnd + vat_amount_vnd

      gross_profit_vnd = net_before_vat_vnd - total_cost
      gross_margin_pct = net_before_vat_vnd > 0 ? ((gross_profit_vnd.to_f / net_before_vat_vnd) * 100.0).round(2) : 0.0

      budget_gap_vnd = budget_vnd ? (net_before_vat_vnd - budget_vnd.to_i) : nil
      within_budget = budget_vnd ? (net_before_vat_vnd <= budget_vnd.to_i) : true

      # Authority & Escalation Gate evaluation
      escalation = evaluate_escalation(
        policies: policies,
        extracted: extracted,
        feasibility: feasibility,
        proposed_disc_pct: proposed_disc_pct,
        net_before_vat_vnd: net_before_vat_vnd,
        gross_margin_pct: gross_margin_pct,
        within_budget: within_budget,
        budget_gap_vnd: budget_gap_vnd
      )

      {
        'applied_tier' => tier,
        'line_items' => line_items,
        'list_subtotal_vnd' => list_subtotal,
        'standard_discount_pct' => std_overall_pct,
        'proposed_discount_pct' => proposed_disc_pct,
        'discount_amount_vnd' => discount_amount_vnd,
        'discount_reason' => discount_reason,
        'net_before_vat_vnd' => net_before_vat_vnd,
        'vat_rate_pct' => vat_rate,
        'vat_amount_vnd' => vat_amount_vnd,
        'grand_total_vnd' => grand_total_vnd,
        'estimated_cost_vnd' => total_cost,
        'gross_profit_vnd' => gross_profit_vnd,
        'gross_margin_pct' => gross_margin_pct,
        'customer_budget_vnd' => budget_vnd,
        'within_budget' => within_budget,
        'budget_gap_vnd' => budget_gap_vnd,
        'authority_gate' => escalation
      }
    end

    private

    def evaluate_escalation(policies:, extracted:, feasibility:, proposed_disc_pct:, net_before_vat_vnd:, gross_margin_pct:, within_budget:, budget_gap_vnd:)
      matrix = policies['authority_matrix'] || {}
      rep = matrix['sales_rep'] || {}
      mgr = matrix['sales_manager'] || {}

      triggers = []
      required_approvers = []

      # 1. Discount & deal value check
      rep_max_disc = (rep['max_overall_discount_pct'] || 5.0).to_f
      mgr_max_disc = (mgr['max_overall_discount_pct'] || 10.0).to_f
      rep_max_deal = (rep['max_deal_value_vnd'] || 1_500_000_000).to_f
      mgr_max_deal = (mgr['max_deal_value_vnd'] || 4_000_000_000).to_f
      rep_min_margin = (rep['min_gross_margin_pct'] || 18.0).to_f
      mgr_min_margin = (mgr['min_gross_margin_pct'] || 14.0).to_f

      if proposed_disc_pct > mgr_max_disc
        triggers << {
          'code' => 'ESC-DISC-EXEC',
          'severity' => 'HIGH',
          'reason' => "Chiết khấu đề xuất #{proposed_disc_pct}% vượt hạn mức Trưởng phòng (#{mgr_max_disc}%).",
          'approver' => 'Ban Giám đốc'
        }
        required_approvers << 'Ban Giám đốc'
      elsif proposed_disc_pct > rep_max_disc
        triggers << {
          'code' => 'ESC-DISC-MGR',
          'severity' => 'MEDIUM',
          'reason' => "Chiết khấu đề xuất #{proposed_disc_pct}% vượt hạn mức Nhân viên Kinh doanh (#{rep_max_disc}%).",
          'approver' => 'Trưởng phòng Kinh doanh'
        }
        required_approvers << 'Trưởng phòng Kinh doanh'
      end

      if net_before_vat_vnd >= mgr_max_deal
        triggers << {
          'code' => 'ESC-VALUE-EXEC',
          'severity' => 'HIGH',
          'reason' => "Giá trị hợp đồng (#{format_vnd(net_before_vat_vnd)}) >= #{format_vnd(mgr_max_deal)}.",
          'approver' => 'Ban Giám đốc'
        }
        required_approvers << 'Ban Giám đốc'
      elsif net_before_vat_vnd >= rep_max_deal
        triggers << {
          'code' => 'ESC-VALUE-MGR',
          'severity' => 'MEDIUM',
          'reason' => "Giá trị hợp đồng (#{format_vnd(net_before_vat_vnd)}) vượt ngưỡng tự duyệt của NVKD (#{format_vnd(rep_max_deal)}).",
          'approver' => 'Trưởng phòng Kinh doanh'
        }
        required_approvers << 'Trưởng phòng Kinh doanh'
      end

      if gross_margin_pct < mgr_min_margin
        triggers << {
          'code' => 'ESC-MARGIN-EXEC',
          'severity' => 'HIGH',
          'reason' => "Biên lợi nhuận gộp #{gross_margin_pct}% thấp hơn sàn Trưởng phòng (#{mgr_min_margin}%).",
          'approver' => 'Ban Giám đốc'
        }
        required_approvers << 'Ban Giám đốc'
      elsif gross_margin_pct < rep_min_margin
        triggers << {
          'code' => 'ESC-MARGIN-MGR',
          'severity' => 'MEDIUM',
          'reason' => "Biên lợi nhuận gộp #{gross_margin_pct}% dưới chuẩn NVKD (#{rep_min_margin}%).",
          'approver' => 'Trưởng phòng Kinh doanh'
        }
        required_approvers << 'Trưởng phòng Kinh doanh'
      end

      # 2. Out-of-catalog check
      if feasibility['has_out_of_catalog']
        ooc_names = (feasibility['out_of_catalog_items'] || []).map { |i| i['requested_name'] }.join(', ')
        triggers << {
          'code' => 'ESC-OUT-OF-CAT',
          'severity' => 'HIGH',
          'reason' => "Có thiết bị/yêu cầu ngoài danh mục chuẩn: #{ooc_names}.",
          'approver' => 'Trưởng phòng Kỹ thuật & Ban Giám đốc'
        }
        required_approvers << 'Trưởng phòng Kỹ thuật'
        required_approvers << 'Ban Giám đốc'
      end

      # 3. Schedule / Capacity conflict check
      unless feasibility.dig('schedule_check', 'feasible')
        triggers << {
          'code' => 'ESC-SCHED-OPS',
          'severity' => 'HIGH',
          'reason' => (feasibility.dig('schedule_check', 'conflict_reasons') || []).join(' '),
          'approver' => 'Trưởng phòng Vận hành & Trưởng phòng Kinh doanh'
        }
        required_approvers << 'Trưởng phòng Vận hành'
        required_approvers << 'Trưởng phòng Kinh doanh'
      end

      # 4. Budget mismatch warning
      unless within_budget
        triggers << {
          'code' => 'ESC-OVER-BUDGET',
          'severity' => 'HIGH',
          'reason' => "Giá sau chiết khấu vẫn vượt ngân sách KH #{format_vnd(budget_gap_vnd.abs)} (không thể hạ giá thêm nếu giữ đủ chức năng bắt buộc).",
          'approver' => 'Trưởng phòng Kinh doanh'
        }
        required_approvers << 'Trưởng phòng Kinh doanh'
      end

      # 5. Penalty / commercial clause
      if (extracted['mandatory_conditions'] || []).any? { |c| c['code'] == 'MAND-PENALTY' }
        triggers << {
          'code' => 'ESC-PENALTY-TERM',
          'severity' => 'MEDIUM',
          'reason' => 'Hồ sơ có điều khoản phạt chậm tiến độ hợp đồng — cần rà soát rủi ro trước khi cam kết.',
          'approver' => 'Trưởng phòng Kinh doanh & Ban Giám đốc'
        }
        required_approvers << 'Trưởng phòng Kinh doanh'
        required_approvers << 'Ban Giám đốc'
      end

      needs_escalation = !triggers.empty?
      {
        'needs_escalation' => needs_escalation,
        'decision' => needs_escalation ? 'CÓ VƯỢT THẨM QUYỀN / CẦN PHÊ DUYỆT' : 'TRONG THẨM QUYỀN',
        'triggers' => triggers,
        'required_approvers' => required_approvers.uniq,
        'highest_authority_level' => required_approvers.include?('Ban Giám đốc') ? 'Ban Giám đốc' : (needs_escalation ? 'Trưởng phòng (KD/KT/VH)' : 'Nhân viên Kinh doanh')
      }
    end

    def format_vnd(num)
      return '0 VND' if num.nil?

      s = num.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1.').reverse
      "#{s} VND"
    end
  end
end

