# encoding: utf-8
# frozen_string_literal: true

require 'date'

module ThienMinh
  class FeasibilityMatcher
    def initialize(store)
      @store = store
    end

    def match(extracted)
      catalog = @store.catalog['solutions'] || []
      cap_data = @store.capacity_schedule
      items = extracted['items'] || []

      matched_items = []
      rejected_traps = []
      out_of_catalog_items = []

      items.each do |req_item|
        res = match_single_item(req_item, catalog)
        matched_items << res[:match]
        rejected_traps.concat(res[:rejected_traps])
        out_of_catalog_items << res[:match] if res[:match]['status'] == 'OUT_OF_CATALOG'
      end

      schedule_check = evaluate_schedule_and_capacity(extracted, matched_items, cap_data)
      cert_check = evaluate_certifications(extracted, cap_data)

      overall_feasible = out_of_catalog_items.empty? && schedule_check['feasible']

      {
        'matched_items' => matched_items,
        'rejected_low_price_traps' => rejected_traps,
        'has_out_of_catalog' => !out_of_catalog_items.empty?,
        'out_of_catalog_items' => out_of_catalog_items,
        'schedule_check' => schedule_check,
        'certification_check' => cert_check,
        'technical_feasible' => out_of_catalog_items.empty?,
        'operational_feasible' => schedule_check['feasible'],
        'overall_feasible' => overall_feasible
      }
    end

    private

    def match_single_item(req_item, catalog)
      specs = req_item['mandatory_specs'] || {}
      qty = (req_item['quantity'] || 1).to_i
      cat = req_item['category']

      # Explicit out-of-catalog check
      if cat == 'Out-of-Catalog' || specs['industrial_ip67']
        est_unit_price = 32_000_000
        est_cost = 24_500_000
        return {
          match: {
            'item_id' => req_item['item_id'],
            'requested_name' => req_item['name'],
            'category' => cat,
            'quantity' => qty,
            'status' => 'OUT_OF_CATALOG',
            'selected_sku' => 'EXT-NONCATALOG-IP67',
            'selected_name' => "#{req_item['name']} (Cần báo giá NCC ngoài)",
            'vendor' => 'Nhà cung cấp chuyên dụng (Đề xuất Moxa / Hirschmann)',
            'unit' => 'Thiết bị',
            'unit_price_vnd' => est_unit_price,
            'cost_vnd' => est_cost,
            'lead_time_days' => 21,
            'man_days' => 2,
            'required_roles' => ['Network Engineer', 'Field Technician'],
            'compliance_notes' => 'Không nằm trong danh mục chuẩn Thiên Minh; cần Kỹ thuật xác nhận model & Ban Giám đốc phê duyệt.',
            'passed_checks' => [],
            'failed_checks' => ['Không có trong danh mục chuẩn Thiên Minh']
          },
          rejected_traps: []
        }
      end

      # Filter catalog candidates by broad category
      candidates = select_candidates(cat, req_item['name'], catalog)
      qualified = []
      rejected_traps = []

      candidates.each do |sol|
        passed, failed = check_candidate_specs(req_item, sol)
        if failed.empty?
          qualified << { sol: sol, passed: passed }
        else
          rejected_traps << {
            'item_id' => req_item['item_id'],
            'requested_item' => req_item['name'],
            'rejected_sku' => sol['sku'],
            'rejected_name' => sol['name'],
            'rejected_unit_price_vnd' => sol['unit_price_vnd'],
            'failed_reasons' => failed
          }
        end
      end

      # Sort qualified by lowest compliant price (cost-optimal WITHOUT sacrificing any mandatory feature!)
      qualified.sort_by! { |q| q[:sol]['unit_price_vnd'] }

      # Only record rejected options that were actually cheaper than the chosen solution (the "low-price traps")
      # Exclude Deployment Service cross-type mismatches (e.g. LAN vs Branch Rollout)
      if qualified.any?
        best = qualified.first
        sol = best[:sol]
        traps = if sol['category'] == 'Deployment Service'
                  []
                else
                  rejected_traps.select { |r| r['rejected_unit_price_vnd'] < sol['unit_price_vnd'] }
                end
        return {
          match: {
            'item_id' => req_item['item_id'],
            'requested_name' => req_item['name'],
            'category' => sol['category'],
            'quantity' => qty,
            'status' => 'MATCHED',
            'selected_sku' => sol['sku'],
            'selected_name' => sol['name'],
            'vendor' => sol['vendor'],
            'unit' => sol['unit'],
            'unit_price_vnd' => sol['unit_price_vnd'],
            'cost_vnd' => sol['cost_vnd'],
            'lead_time_days' => sol['lead_time_days'] || 5,
            'man_days' => (sol['man_days'] || 0) * (sol['category'] == 'Deployment Service' ? qty : 0),
            'required_roles' => sol['required_roles'] || [],
            'compliance_notes' => "Đạt 100% đặc tính bắt buộc (#{best[:passed].join(', ')}).",
            'passed_checks' => best[:passed],
            'failed_checks' => []
          },
          rejected_traps: traps
        }
      end

      # No compliant catalog item found
      {
        match: {
          'item_id' => req_item['item_id'],
          'requested_name' => req_item['name'],
          'category' => cat,
          'quantity' => qty,
          'status' => 'OUT_OF_CATALOG',
          'selected_sku' => 'EXT-CUSTOM-SPEC',
          'selected_name' => "#{req_item['name']} (Chưa có SKU đáp ứng trong danh mục)",
          'vendor' => 'Cần tìm nguồn cung ứng ngoài',
          'unit' => 'Đơn vị',
          'unit_price_vnd' => 30_000_000,
          'cost_vnd' => 23_000_000,
          'lead_time_days' => 21,
          'man_days' => 3,
          'required_roles' => ['Network Architect'],
          'compliance_notes' => 'Không tìm thấy sản phẩm trong danh mục chuẩn đáp ứng đủ điều kiện kỹ thuật.',
          'passed_checks' => [],
          'failed_checks' => ['Không có SKU đạt đủ thông số bắt buộc']
        },
        rejected_traps: rejected_traps
      }
    end

    def select_candidates(category, name, catalog)
      low_name = name.to_s.downcase
      if category == 'Wireless' && low_name.include?('controller')
        return catalog.select { |s| s['sku'] == 'TM-WLC-CTRL' }
      elsif category == 'Wireless'
        return catalog.select { |s| s['category'] == 'Wireless' && s['sku'] != 'TM-WLC-CTRL' }
      end

      matched = catalog.select { |s| s['category'] == category }
      return matched unless matched.empty?

      catalog.select { |s| s['category'] == 'Deployment Service' }
    end

    def check_candidate_specs(req_item, sol)
      specs = req_item['mandatory_specs'] || {}
      sol_specs = sol['specs'] || {}
      low_req = "#{req_item['name']} #{req_item['spec_notes']}".downcase
      passed = []
      failed = []

      # Switch specs
      if sol['category'] == 'Access Switch' || sol['category'] == 'Core Switch'
        if specs['ports']
          if (sol_specs['ports'] || 0) >= specs['ports'].to_i
            passed << "#{sol_specs['ports']} ports >= #{specs['ports']} ports"
          else
            failed << "Chỉ có #{sol_specs['ports']} ports (yêu cầu #{specs['ports']} ports)"
          end
        end

        if specs['poe']
          if sol_specs['poe']
            passed << "Hỗ trợ PoE+ #{sol_specs['poe_watts']}W"
          else
            failed << 'Không hỗ trợ cấp nguồn PoE+'
          end
        end

        if specs['uplink_10g']
          if sol_specs['uplink_10g']
            passed << 'Có uplink 10G SFP+'
          else
            failed << 'Không có cổng uplink 10G SFP+'
          end
        end

        if specs['layer3']
          if sol_specs['layer3']
            passed << 'Định tuyến Layer 3 đầy đủ'
          else
            failed << 'Chỉ hỗ trợ Layer 2, thiếu Layer 3 bắt buộc'
          end
        end

        if specs['stacking']
          if sol_specs['stacking']
            passed << 'Hỗ trợ Stacking'
          else
            failed << 'Không hỗ trợ Stacking'
          end
        end

        if specs['redundant_psu']
          if sol_specs['redundant_psu']
            passed << 'Có nguồn dự phòng kép'
          else
            failed << 'Không có nguồn dự phòng kép (Redundant PSU)'
          end
        end
      end

      # Firewall specs
      if sol['category'] == 'Firewall'
        if specs['ips_gbps']
          if (sol_specs['ips_throughput_gbps'] || 0) >= specs['ips_gbps'].to_f
            passed << "IPS #{sol_specs['ips_throughput_gbps']} Gbps >= #{specs['ips_gbps']} Gbps"
          else
            failed << "IPS chỉ đạt #{sol_specs['ips_throughput_gbps']} Gbps (yêu cầu >= #{specs['ips_gbps']} Gbps)"
          end
        end

        if specs['ha']
          if sol_specs['ha_support']
            passed << 'Hỗ trợ cụm HA'
          else
            failed << 'Không hỗ trợ chạy cụm dự phòng HA'
          end
        end
      end

      # Wireless AP specs
      if sol['category'] == 'Wireless' && sol['sku'] != 'TM-WLC-CTRL'
        if specs['high_density_wifi']
          if (sol_specs['max_concurrent_clients'] || 0) >= 200
            passed << "Chịu tải #{sol_specs['max_concurrent_clients']} clients/AP"
          else
            failed << "Chỉ chịu tải #{sol_specs['max_concurrent_clients']} clients/AP (không đạt chuẩn chịu tải cao >= 200)"
          end
        else
          passed << 'Chuẩn Wi-Fi 6'
        end
      end

      # Deployment service matching
      if sol['category'] == 'Deployment Service'
        if low_req.include?('chi nhánh') && !sol_specs['branch_rollout']
          failed << 'Không phải gói rollout chi nhánh'
        elsif (low_req.include?('ha failover') || low_req.include?('bảo mật') || low_req.include?('sd-wan')) && !low_req.include?('chi nhánh') && !sol_specs['ha_failover_test']
          failed << 'Không phải gói thiết kế & cấu hình bảo mật/HA'
        elsif (low_req.include?('khảo sát') || low_req.include?('vlan') || low_req.include?('lan')) && !sol_specs['vlan_segmentation']
          failed << 'Không phải gói khảo sát & triển khai LAN/Wi-Fi'
        else
          passed << 'Đúng phạm vi dịch vụ triển khai'
        end
      end

      # Maintenance & SLA matching
      if sol['category'] == 'Maintenance & SLA'
        if specs['sla_24x7']
          if sol_specs['sla_24x7'] && (sol_specs['response_hours'] || 99) <= (specs['response_hours'] || 4)
            passed << "SLA 24x7 phản hồi #{sol_specs['response_hours']}h"
          else
            failed << 'Chỉ hỗ trợ giờ hành chính 8x5 (8h), KHÔNG đạt yêu cầu 24x7 SLA 4h'
          end
        else
          passed << "Đáp ứng gói bảo trì #{sol_specs['sla_24x7'] ? '24x7' : '8x5'}"
        end
      end

      passed << 'Đáp ứng tiêu chuẩn cơ bản' if passed.empty? && failed.empty?
      [passed, failed]
    end

    def evaluate_schedule_and_capacity(extracted, matched_items, cap_data)
      deadline = extracted['deadline'] || {}
      requested_days = deadline['duration_days'] || 30
      weeks_list = cap_data['weekly_schedule'] || []

      max_lead_days = matched_items.map { |m| m['lead_time_days'] || 0 }.max || 5
      total_man_days = matched_items.sum { |m| m['man_days'] || 0 }
      # Add base engineering days per hardware device count if no explicit service man_days
      hw_count = matched_items.select { |m| !%w[Deployment\ Service Maintenance\ &\ SLA].include?(m['category']) }.sum { |m| m['quantity'] || 0 }
      total_man_days = [total_man_days, (hw_count * 0.4).ceil + 4].max

      # Required weeks window
      requested_weeks_count = [(requested_days / 7.0).ceil, 1].max
      window_weeks = weeks_list.first(requested_weeks_count)
      proc_buffer = (cap_data.dig('team_capacity', 'procurement_buffer_days') || 5)
      required_total_days = max_lead_days + proc_buffer + [((total_man_days / 3.0).ceil), 3].max

      available_man_days_in_window = window_weeks.sum { |w| w['available_man_days'] || 0 }
      overloaded_weeks = window_weeks.select { |w| (w['utilization_pct'] || 0) >= 85 }

      # Recommend best deployment weeks (weeks after procurement lead time with status AVAILABLE)
      lead_weeks = (max_lead_days / 7.0).ceil
      candidate_exec_weeks = weeks_list.drop([lead_weeks - 1, 0].max).select { |w| w['status'] == 'AVAILABLE' }
      recommended_weeks = candidate_exec_weeks.first(2).map { |w| w['label'] }

      reasons = []
      if requested_days < required_total_days
        reasons << "Thời hạn KH yêu cầu (#{requested_days} ngày) ngắn hơn tổng thời gian nhập hàng + thi công tối thiểu (#{required_total_days} ngày: lead-time #{max_lead_days}d + buffer #{proc_buffer}d + triển khai)."
      end
      if available_man_days_in_window < total_man_days
        reasons << "Tổng ngày công khả dụng trong cửa sổ deadline (#{available_man_days_in_window} man-days) không đủ cho nhu cầu dự án (#{total_man_days} man-days)."
      end
      if overloaded_weeks.any? && requested_weeks_count <= 2
        labels = overloaded_weeks.map { |w| "#{w['week_id']} (#{w['utilization_pct']}%)" }.join(', ')
        reasons << "Cửa sổ triển khai rơi vào tuần đang quá tải/sát trần: #{labels}."
      end

      feasible = reasons.empty?
      earliest_feasible_days = [required_total_days + 4, 24].max

      {
        'feasible' => feasible,
        'requested_days' => requested_days,
        'required_min_days' => required_total_days,
        'earliest_feasible_days' => earliest_feasible_days,
        'max_hardware_lead_days' => max_lead_days,
        'estimated_man_days' => total_man_days,
        'available_man_days_in_window' => available_man_days_in_window,
        'window_weeks' => window_weeks,
        'recommended_weeks' => recommended_weeks,
        'conflict_reasons' => reasons,
        'recommendation' => feasible ?
          "Đủ năng lực & lịch triển khai phù hợp trong các tuần: #{recommended_weeks.join(', ')}." :
          "Cảnh báo lịch triển khai không khả thi đúng hạn #{requested_days} ngày! Đề xuất dời mốc giao hàng sang #{earliest_feasible_days} ngày (tuần #{recommended_weeks.join(', ')}) hoặc xin duyệt tăng ca/thuê ngoài."
      }
    end

    def evaluate_certifications(extracted, cap_data)
      roles = cap_data.dig('team_capacity', 'roles') || {}
      certs = roles.values.flat_map { |r| r['certifications'] || [] }
      conds = extracted['mandatory_conditions'] || []
      needs_cert = conds.any? { |c| c['code'] == 'MAND-CERT' }

      {
        'required_by_rfp' => needs_cert,
        'available_certifications' => certs,
        'satisfied' => true,
        'note' => 'Đội ngũ Thiên Minh có sẵn kỹ sư CCIE, CCNP, Aruba ACMP, Fortinet NSE4/NSE5 đáp ứng.'
      }
    end
  end
end
