# encoding: utf-8
# frozen_string_literal: true

require 'json'
require 'date'

module ThienMinh
  class RfpExtractor
    def initialize(llm_client)
      @llm = llm_client
    end

    def extract_and_check(raw_text, title = '')
      llm_note = nil
      used_llm = false

      if @llm && @llm.llm_enabled?
        llm_res = try_llm_extract(raw_text, title)
        if llm_res['ok'] && llm_res['data'].is_a?(Hash)
          extracted = normalize_llm_output(llm_res['data'], raw_text, title)
          used_llm = true
          llm_note = "Phân tích bằng LLM (#{llm_res['provider'].upcase} / #{llm_res['model']})"
        else
          extracted = heuristic_extract(raw_text, title)
          llm_note = "LLM fallback sang Offline Engine (#{llm_res['error']})"
        end
      else
        extracted = heuristic_extract(raw_text, title)
        llm_note = 'Phân tích bằng Offline NLP & Rule Engine (Hybrid sẵn sàng)'
      end

      gate = evaluate_completeness(extracted, raw_text)
      {
        'used_llm' => used_llm,
        'engine_note' => llm_note,
        'extracted' => extracted,
        'completeness_gate' => gate
      }
    end

    private

    def try_llm_extract(raw_text, title)
      system_prompt = <<~PROMPT
        Bạn là AI Agent phân tích hồ sơ mời chào giá (RFP/RFQ) cho Công ty Thiên Minh (thiết bị mạng & dịch vụ triển khai).
        Hãy trích xuất dữ liệu thành JSON thuần với cấu trúc chính xác sau:
        {
          "customer_name": "string",
          "location": "string or null",
          "scale_summary": "string or null",
          "deadline": {
            "raw_text": "string or null",
            "duration_days": integer or null,
            "target_date": "YYYY-MM-DD or null"
          },
          "budget": {
            "amount_vnd": number or null,
            "vat_excluded": boolean,
            "raw_text": "string or null"
          },
          "requested_discount_pct": number or null,
          "items": [
            {
              "item_id": "ITEM-1",
              "name": "string",
              "category": "Access Switch|Core Switch|Firewall|Wireless|SD-WAN / Router|Deployment Service|Maintenance & SLA|Out-of-Catalog",
              "quantity": integer or null,
              "quantity_ambiguous": boolean,
              "mandatory_specs": {
                "ports": integer or null,
                "poe": boolean,
                "uplink_10g": boolean,
                "layer3": boolean,
                "stacking": boolean,
                "redundant_psu": boolean,
                "ips_gbps": number or null,
                "ha": boolean,
                "high_density_wifi": boolean,
                "seamless_roaming": boolean,
                "sdwan": boolean,
                "industrial_ip67": boolean,
                "sla_24x7": boolean,
                "response_hours": integer or null,
                "duration_months": integer or null
              },
              "spec_notes": "string",
              "source_excerpt": "string"
            }
          ],
          "mandatory_conditions": [
            { "code": "string", "label": "string", "source_excerpt": "string" }
          ],
          "ambiguous_points": ["string"]
        }
        Không bịa đặt thông tin không có trong văn bản. Nếu số lượng mơ hồ ("mấy con", "vài bộ", không nêu số) hãy đặt quantity = null và quantity_ambiguous = true.
      PROMPT

      user_prompt = "Tiêu đề hồ sơ: #{title}\n\nNội dung RFP/RFQ:\n#{raw_text}"
      @llm.generate_json(system_prompt, user_prompt)
    end

    def normalize_llm_output(data, raw_text, title)
      # Merge deterministic safety checks so critical numbers/flags from Vietnamese text are never lost
      heur = heuristic_extract(raw_text, title)
      data['customer_name'] ||= heur['customer_name']
      data['location'] ||= heur['location']
      data['scale_summary'] ||= heur['scale_summary']
      data['deadline'] ||= heur['deadline']
      data['budget'] ||= heur['budget']
      data['requested_discount_pct'] ||= heur['requested_discount_pct']
      data['items'] = heur['items'] if !data['items'].is_a?(Array) || data['items'].empty?
      data['mandatory_conditions'] = heur['mandatory_conditions'] if !data['mandatory_conditions'].is_a?(Array) || data['mandatory_conditions'].empty?
      data['segments'] = heur['segments']
      data
    end

    def heuristic_extract(raw_text, title)
      text = raw_text.to_s
      norm = text.downcase
      segments = text.split(/\n\s*\n/).map(&:strip).reject(&:empty?)

      customer_name = extract_customer_name(text, title)
      location = extract_location(text)
      scale_summary = extract_scale(text)
      deadline = extract_deadline(text)
      budget = extract_budget(text)
      requested_discount = extract_requested_discount(text)
      items = extract_items(text, segments)
      mandatory_conditions = extract_mandatory_conditions(text, segments)

      {
        'customer_name' => customer_name,
        'location' => location,
        'scale_summary' => scale_summary,
        'deadline' => deadline,
        'budget' => budget,
        'requested_discount_pct' => requested_discount,
        'items' => items,
        'mandatory_conditions' => mandatory_conditions,
        'segments' => segments.each_with_index.map { |s, i| { 'index' => i + 1, 'text' => s } },
        'ambiguous_points' => detect_ambiguous_phrases(norm)
      }
    end

    def extract_customer_name(text, title)
      patterns = [
        /(Tập đoàn\s+[^\n,\.()]{3,50})/i,
        /(Bệnh viện\s+[^\n,\.()]{3,50})/i,
        /(Công ty\s+(?:CP\s+|TNHH\s+)?[^\n,\.()]{3,50})/i,
        /(Chuỗi\s+(?:Bán lẻ|Siêu thị)\s+[^\n,\.()]{3,40})/i,
        /(Ngân hàng\s+[^\n,\.()]{3,50})/i
      ]
      patterns.each do |pat|
        if text =~ pat
          candidate = Regexp.last_match(1).strip
          next if candidate.downcase.include?('thiên minh')
          return candidate.split(/\s+(?:đang|tại|cần|chuẩn bị)\b/i).first.strip
        end
      end
      if title && title.include?(' - ')
        return title.split(' - ').last.strip
      end
      'Khách hàng doanh nghiệp'
    end

    def extract_location(text)
      locs = []
      locs << Regexp.last_match(1).strip if text =~ /(Quận\s+\d+[^,\n\.]*(?:,\s*TP\.?\s*HCM)?)/i
      locs << Regexp.last_match(1).strip if text =~ /((?:cơ sở\s+)?Bình Thạnh|TP\.?\s*HCM|Hà Nội|Đà Nẵng|KCN\s+[^\n,\.]+|miền Nam)/i
      locs << Regexp.last_match(1).strip if text =~ /(\d+\s*chi nhánh[^\n,\.]*)/i
      locs.uniq!
      locs.empty? ? nil : locs.join(' | ')
    end

    def extract_scale(text)
      parts = []
      parts << Regexp.last_match(0).strip if text =~ /(\d+\s*tầng)/i
      parts << Regexp.last_match(0).strip if text =~ /(\d+\s*(?:nhân sự|user|người dùng|nhân viên))/i
      parts << Regexp.last_match(0).strip if text =~ /(\d+\s*chi nhánh)/i
      parts << Regexp.last_match(0).strip if text =~ /(\d+\s*khu\s*khám[^\n,\.]*)/i
      parts.empty? ? nil : parts.uniq.join(', ')
    end

    def extract_deadline(text)
      duration_days = nil
      raw_match = nil
      target_date = nil

      if text =~ /(?:trong\s+vòng|trong|thời\s*hạn[^\n:]*:?|tiến\s*độ[^\n:]*:?)\s*(\d+)\s*tuần/i
        weeks = Regexp.last_match(1).to_i
        duration_days = weeks * 7
        raw_match = "#{weeks} tuần"
      elsif text =~ /(?:trong\s+vòng|trong|gấp\s+trong)\s*(\d+)\s*ngày/i
        duration_days = Regexp.last_match(1).to_i
        raw_match = "#{duration_days} ngày"
      end

      if text =~ /(?:trước\s*(?:ngày)?|hoàn\s*tất\s*trước)\s*(\d{1,2})\/(\d{1,2})\/(\d{4})/i
        d = Regexp.last_match(1).to_i
        m = Regexp.last_match(2).to_i
        y = Regexp.last_match(3).to_i
        begin
          dt = Date.new(y, m, d)
          target_date = dt.strftime('%Y-%m-%d')
          today = Date.new(2026, 11, 12)
          calc_days = (dt - today).to_i
          duration_days ||= [calc_days, 1].max
          raw_match = [raw_match, "trước #{d}/#{m}/#{y}"].compact.join(' - ')
        rescue ArgumentError
          # ignore invalid date
        end
      end

      {
        'raw_text' => raw_match,
        'duration_days' => duration_days,
        'target_date' => target_date
      }
    end

    def extract_budget(text)
      amount_vnd = nil
      raw_text = nil
      vat_excluded = !(text =~ /đã\s*(?:bao\s*gồm\s*)?vat/i)

      if text =~ /(?:ngân\s*sách[^\d\n]{0,30})(\d+(?:[.,]\d+)?)\s*(tỷ|tỉ|triệu)/i
        num = Regexp.last_match(1).tr(',', '.').to_f
        unit = Regexp.last_match(2).downcase
        mult = (unit == 'tỷ' || unit == 'tỉ') ? 1_000_000_000 : 1_000_000
        amount_vnd = (num * mult).round
        raw_text = "#{Regexp.last_match(1)} #{unit} VND"
      elsif text =~ /(?:ngân\s*sách[^\d\n]{0,30})(\d{1,3}(?:[.,]\d{3}){2,})\s*(?:vnd|đ|vnđ)/i
        amount_vnd = Regexp.last_match(1).gsub(/[.,]/, '').to_i
        raw_text = "#{Regexp.last_match(1)} VND"
      end

      {
        'amount_vnd' => amount_vnd,
        'vat_excluded' => vat_excluded,
        'raw_text' => raw_text
      }
    end

    def extract_requested_discount(text)
      if text =~ /(?:chiết\s*khấu|giảm\s*giá)[^\d\n]{0,25}(\d+(?:[.,]\d+)?)\s*%/i
        return Regexp.last_match(1).tr(',', '.').to_f
      end
      nil
    end

    def extract_items(text, segments)
      # Split into bullet lines and clauses so compound sentences ("... switch 48 port ..., cùng 01 core switch ...")
      # and ("24 Access Point ... kèm 12 Switch Access ...") extract cleanly!
      raw_lines = text.split(/\n+/).map(&:strip).reject(&:empty?)
      clauses = []
      raw_lines.each do |line|
        # Protect decimal numbers like 1.65 or 5.5 and dates before splitting
        parts = line.split(/(?<=[a-zA-ZÀ-ỹ0-9\)])\.\s+(?=[A-ZĐÀ-Ỹ\d-])|;\s*|,\s*(?=cùng\s+\d+|kèm\s+\d+)/)
        parts.each do |p|
          s = p.strip
          clauses << s unless s.empty?
        end
      end

      items = []
      idx = 0

      add_item = lambda do |item|
        idx += 1
        item['item_id'] = "ITEM-#{idx}"
        items << item
      end

      # 1. Check Industrial Switch IP67 (Out-of-Catalog)
      clauses.each do |line|
        low = line.downcase
        if low.include?('switch') && (low.include?('ip67') || low.include?('công nghiệp') || low.include?('-20'))
          qty = extract_qty_for_keyword(line, /switch/i)
          add_item.call({
            'name' => 'Switch công nghiệp chống bụi nước chuẩn IP67',
            'category' => 'Out-of-Catalog',
            'quantity' => qty,
            'quantity_ambiguous' => qty.nil?,
            'mandatory_specs' => { 'industrial_ip67' => true },
            'spec_notes' => 'Hoạt động môi trường khắc nghiệt -20°C / IP67 (ngoài danh mục chuẩn)',
            'source_excerpt' => line
          })
        end
      end

      # 2. Core Switch (only when explicitly "core switch", NOT "đấu nối lên Core")
      clauses.each do |line|
        low = line.downcase
        if low.include?('core switch')
          qty = extract_qty_for_keyword(line, /core\s+switch/i)
          add_item.call({
            'name' => 'Core Switch 10G SFP+ Layer 3',
            'category' => 'Core Switch',
            'quantity' => qty,
            'quantity_ambiguous' => qty.nil?,
            'mandatory_specs' => {
              'ports' => extract_ports(low) || 24,
              'uplink_10g' => true,
              'layer3' => true,
              'redundant_psu' => low.include?('nguồn dự phòng') || low.include?('redundant'),
              'stacking' => low.include?('stack')
            },
            'spec_notes' => line,
            'source_excerpt' => line
          })
        end
      end

      # 3. Access Switch (48-port / 24-port / ambiguous)
      clauses.each do |line|
        low = line.downcase
        next unless low.include?('switch')
        next if low.include?('core switch') || low.include?('ip67') || low.include?('công nghiệp')
        # Skip intro/context sentences like "nâng cấp cụm bảo mật và switch phân phối cho 350 nhân sự"
        next if intro_context_line?(low)

        qty = extract_qty_for_keyword(line, /switch(?:\s+access)?/i)
        ports = extract_ports(low)
        poe = low.include?('poe') || low.include?('camera')
        l3 = low.include?('layer 3') || low.include?('l3')
        stack = low.include?('stack')
        uplink10g = low.include?('10g') || low.include?('sfp+')

        add_item.call({
          'name' => ports ? "Switch Access #{ports}-Port #{poe ? 'PoE+' : ''} #{l3 ? 'Layer 3' : ''}".squeeze(' ').strip : 'Switch mạng (chưa rõ số port/PoE)',
          'category' => 'Access Switch',
          'quantity' => qty,
          'quantity_ambiguous' => qty.nil?,
          'spec_ambiguous' => ports.nil?,
          'mandatory_specs' => {
            'ports' => ports,
            'poe' => poe,
            'uplink_10g' => uplink10g,
            'layer3' => l3,
            'stacking' => stack
          },
          'spec_notes' => line,
          'source_excerpt' => line
        })
      end

      # 4. Firewall / NGFW
      clauses.each do |line|
        low = line.downcase
        next unless low.include?('firewall') || low.include?('ngfw') || low.include?('tường lửa')
        next if low.include?('dịch vụ') && !low.include?('thiết bị') && !(low =~ /\d+\s*firewall/i)

        qty = extract_qty_for_keyword(line, /(?:firewall(?:\s+ngfw)?(?:\s+doanh\s+nghiệp)?|ngfw|tường lửa)/i)
        ips = nil
        if low =~ /ips[^\d]{0,20}(\d+(?:[.,]\d+)?)\s*gbps/i
          ips = Regexp.last_match(1).tr(',', '.').to_f
        end
        ha = !!(low =~ /\bha\b|active-passive|active-active|cụm/i)
        uplink10g = low.include?('10g') || low.include?('sfp+')

        add_item.call({
          'name' => ips ? "Firewall NGFW (IPS >= #{ips} Gbps#{ha ? ', HA' : ''})" : 'Firewall bảo mật (chưa rõ thông số IPS/User)',
          'category' => 'Firewall',
          'quantity' => qty,
          'quantity_ambiguous' => qty.nil?,
          'spec_ambiguous' => ips.nil?,
          'mandatory_specs' => {
            'ips_gbps' => ips,
            'ha' => ha,
            'uplink_10g' => uplink10g
          },
          'spec_notes' => line,
          'source_excerpt' => line
        })
      end

      # 5. Wireless Access Point & Controller
      clauses.each do |line|
        low = line.downcase
        if low.include?('access point') || low.include?('wi-fi') || low.include?('wifi')
          next if low.include?('dịch vụ') || low.include?('chi nhánh miền nam')
          unless low.include?('wireless controller') && !low.include?('access point') && !low.include?('wi-fi') && !low.include?('wifi')
            qty = extract_qty_for_keyword(line, /(?:access\s*point|ap\b|wi-fi|wifi)/i)
            high_density = low.include?('200') || low.include?('chịu tải cao') || low.include?('doanh nghiệp') || low.include?('bệnh nhân') || low.include?('roaming')
            roaming = low.include?('roaming') || low.include?('controller')

            add_item.call({
              'name' => qty ? "Access Point Wi-Fi 6 #{high_density ? 'Enterprise' : 'Văn phòng'}" : 'Hệ thống Wi-Fi / Access Point (chưa rõ số lượng AP)',
              'category' => 'Wireless',
              'quantity' => qty,
              'quantity_ambiguous' => qty.nil?,
              'spec_ambiguous' => qty.nil?,
              'mandatory_specs' => {
                'high_density_wifi' => high_density,
                'seamless_roaming' => roaming,
                'poe' => true
              },
              'spec_notes' => line,
              'source_excerpt' => line
            })
          end
        end

        if (low.include?('wireless controller') || low.include?('bộ điều khiển wifi')) && !items.any? { |it| it['name'].include?('Controller') }
          qty = extract_qty_for_keyword(line, /(?:bộ\s+)?(?:wireless\s*controller|controller)/i) || 1
          add_item.call({
            'name' => 'Wireless Controller quản lý tập trung',
            'category' => 'Wireless',
            'quantity' => qty,
            'quantity_ambiguous' => false,
            'mandatory_specs' => { 'seamless_roaming' => true, 'controller' => true },
            'spec_notes' => line,
            'source_excerpt' => line
          })
        end
      end

      # 6. SD-WAN
      clauses.each do |line|
        low = line.downcase
        next unless low.include?('sd-wan') || low.include?('sdwan')
        next if low.include?('dịch vụ') || low.include?('triển khai') || low.include?('tiêu đề') || low.include?('yêu cầu chào giá')

        qty = extract_qty_for_keyword(line, /(?:thiết\s*bị\s*sd-?wan|sd-?wan)/i)
        add_item.call({
          'name' => 'Thiết bị SD-WAN chi nhánh (Dual WAN + 4G Failover)',
          'category' => 'SD-WAN / Router',
          'quantity' => qty,
          'quantity_ambiguous' => qty.nil?,
          'mandatory_specs' => { 'sdwan' => true },
          'spec_notes' => line,
          'source_excerpt' => line
        })
      end

      # Deduplicate/supersede: if a category has explicit complete items (e.g. after customer clarification),
      # remove earlier ambiguous placeholder items in the same category!
      items_by_cat = items.group_by { |it| it['category'] }
      cleaned_items = items.reject do |it|
        (it['quantity_ambiguous'] || it['spec_ambiguous']) &&
          (items_by_cat[it['category']] || []).any? { |other| !other['quantity_ambiguous'] && !other['spec_ambiguous'] }
      end
      # Re-number item_id cleanly
      idx = cleaned_items.size
      cleaned_items.each_with_index { |it, i| it['item_id'] = "ITEM-#{i + 1}" }
      items = cleaned_items

      # 7. Deployment Services
      norm = text.downcase
      if norm.include?('triển khai') || norm.include?('lắp đặt') || norm.include?('khảo sát') || norm.include?('cấu hình')
        if norm.include?('chi nhánh') && text =~ /(\d+)\s*chi nhánh/i
          branches = Regexp.last_match(1).to_i
          add_item.call({
            'name' => "Dịch vụ triển khai chuẩn hóa #{branches} chi nhánh & SD-WAN",
            'category' => 'Deployment Service',
            'quantity' => branches,
            'quantity_ambiguous' => false,
            'mandatory_specs' => { 'branch_rollout' => true },
            'spec_notes' => "Rollout #{branches} chi nhánh",
            'source_excerpt' => find_excerpt(segments, /triển khai|chi nhánh/i)
          })
        end

        if norm.include?('khảo sát') || norm.include?('lắp đặt') || norm.include?('vlan') || norm.include?('as-built')
          floors = (text =~ /(\d+)\s*tầng/i) ? Regexp.last_match(1).to_i : 1
          packs = [floors >= 3 ? 2 : 1, 1].max
          add_item.call({
            'name' => 'Dịch vụ khảo sát, lắp đặt & cấu hình LAN/Wi-Fi/VLAN',
            'category' => 'Deployment Service',
            'quantity' => packs,
            'quantity_ambiguous' => false,
            'mandatory_specs' => { 'vlan_segmentation' => true },
            'spec_notes' => 'Khảo sát, lắp đặt rack, cấu hình VLAN, bàn giao As-Built',
            'source_excerpt' => find_excerpt(segments, /khảo sát|lắp đặt|vlan/i)
          })
        end

        if norm.include?('ha failover') || norm.include?('cấu hình bảo mật') || norm.include?('cụm bảo mật') || (norm.include?('thiết kế') && (norm.include?('firewall') || norm.include?('sd-wan')))
          add_item.call({
            'name' => 'Dịch vụ thiết kế & triển khai Bảo mật Firewall HA / SD-WAN',
            'category' => 'Deployment Service',
            'quantity' => 1,
            'quantity_ambiguous' => false,
            'mandatory_specs' => { 'ha_failover_test' => true },
            'spec_notes' => 'Thiết kế kiến trúc bảo mật, cấu hình HA/IPS/VPN & nghiệm thu',
            'source_excerpt' => find_excerpt(segments, /failover|bảo mật|sd-wan|firewall/i)
          })
        end
      end

      # 8. Maintenance & SLA
      if norm.include?('bảo trì') || norm.include?('sla')
        sla_24x7 = norm.include?('24x7') || norm.include?('24/7') || norm.include?('4 giờ') || norm.include?('4h')
        sla_8x5 = norm.include?('8x5') || norm.include?('8 giờ') || norm.include?('8h')
        months = (text =~ /(\d+)\s*tháng/i) ? Regexp.last_match(1).to_i : 12
        years = [(months / 12.0).ceil, 1].max

        add_item.call({
          'name' => sla_24x7 ? "Gói bảo trì 24x7 SLA 4 giờ (#{months} tháng)" : "Gói bảo trì 8x5 SLA 8 giờ (#{months} tháng)",
          'category' => 'Maintenance & SLA',
          'quantity' => years,
          'quantity_ambiguous' => false,
          'spec_ambiguous' => !sla_24x7 && !sla_8x5,
          'mandatory_specs' => {
            'sla_24x7' => sla_24x7,
            'response_hours' => sla_24x7 ? 4 : 8,
            'duration_months' => months
          },
          'spec_notes' => find_excerpt(segments, /bảo trì|sla/i),
          'source_excerpt' => find_excerpt(segments, /bảo trì|sla/i)
        })
      end

      items
    end

    def intro_context_line?(low)
      return true if low.include?('bối cảnh') || low.include?('tổng quan') || low.include?('giới thiệu')
      # If sentence talks about "nâng cấp ... cho <N> nhân sự" without port/model specs, skip as narrative header
      return true if low.include?('nâng cấp') && low.include?('nhân sự') && !(low =~ /\d+\s*(?:port|cổng|switch)/)

      false
    end

    def extract_qty_before(line, _kw)
      if line =~ /(\d+)\s*(?:chiếc|bộ|con|thiết\s*bị)?\s*switch/i
        return Regexp.last_match(1).to_i
      end
      nil
    end

    def extract_qty_for_keyword(line, kw_regex)
      if line =~ /(\d+)\s*(?:chiếc|bộ|con|thiết\s*bị)?\s*#{kw_regex.source}/i
        return Regexp.last_match(1).to_i
      end
      nil
    end

    def extract_ports(low)
      if low =~ /(\d+)\s*(?:port|cổng)/i
        return Regexp.last_match(1).to_i
      end
      nil
    end

    def extract_mandatory_conditions(text, segments)
      conds = []
      norm = text.downcase

      if norm.include?('co/cq') || norm.include?('chính hãng')
        conds << { 'code' => 'MAND-COCQ', 'label' => 'Bắt buộc cung cấp đầy đủ CO/CQ chính hãng', 'source_excerpt' => find_excerpt(segments, /co\/cq|chính hãng/i) }
      end
      if norm.include?('poe')
        conds << { 'code' => 'MAND-POE', 'label' => 'Switch bắt buộc cấp nguồn PoE+', 'source_excerpt' => find_excerpt(segments, /poe/i) }
      end
      if norm.include?('10g') || norm.include?('sfp+')
        conds << { 'code' => 'MAND-10G', 'label' => 'Bắt buộc có cổng uplink 10G SFP+', 'source_excerpt' => find_excerpt(segments, /10g|sfp\+/i) }
      end
      if norm.include?('layer 3') || norm.include?('l3')
        conds << { 'code' => 'MAND-L3', 'label' => 'Switch hỗ trợ định tuyến Layer 3 đầy đủ', 'source_excerpt' => find_excerpt(segments, /layer 3|l3/i) }
      end
      if norm.include?('redundant') || norm.include?('nguồn dự phòng')
        conds << { 'code' => 'MAND-RPSU', 'label' => 'Core Switch có nguồn dự phòng kép (Redundant PSU)', 'source_excerpt' => find_excerpt(segments, /redundant|nguồn dự phòng/i) }
      end
      if norm =~ /ips[^\d]{0,20}(\d+(?:[.,]\d+)?)\s*gbps/i
        conds << { 'code' => 'MAND-IPS', 'label' => "Firewall bắt buộc thông lượng IPS >= #{Regexp.last_match(1)} Gbps", 'source_excerpt' => find_excerpt(segments, /ips/i) }
      end
      if norm =~ /\bha\b|active-passive|active-active/i
        conds << { 'code' => 'MAND-HA', 'label' => 'Firewall chạy cấu hình dự phòng HA', 'source_excerpt' => find_excerpt(segments, /\bha\b|active-passive|active-active/i) }
      end
      if norm.include?('24x7') || norm.include?('24/7') || norm.include?('4 giờ') || norm.include?('4h')
        conds << { 'code' => 'MAND-SLA-24X7', 'label' => 'Bảo trì 24x7 với SLA ứng cứu trong 4 giờ', 'source_excerpt' => find_excerpt(segments, /24x7|24\/7|4 giờ|4h/i) }
      elsif norm.include?('8x5')
        conds << { 'code' => 'MAND-SLA-8X5', 'label' => 'Bảo trì 8x5 phản hồi trong 8 giờ', 'source_excerpt' => find_excerpt(segments, /8x5/i) }
      end
      if norm.include?('ccnp') || norm.include?('nse4') || norm.include?('chứng chỉ')
        conds << { 'code' => 'MAND-CERT', 'label' => 'Kỹ sư triển khai có chứng chỉ chuyên môn (CCNP/NSE4)', 'source_excerpt' => find_excerpt(segments, /ccnp|nse4|chứng chỉ/i) }
      end
      if norm.include?('phạt chậm tiến độ') || norm.include?('phạt')
        conds << { 'code' => 'MAND-PENALTY', 'label' => 'Điều khoản phạt chậm tiến độ hợp đồng', 'source_excerpt' => find_excerpt(segments, /phạt/i) }
      end
      if norm.include?('ip67') || norm.include?('-20')
        conds << { 'code' => 'MAND-IP67', 'label' => 'Thiết bị công nghiệp chuẩn IP67 (-20°C) cho kho lạnh', 'source_excerpt' => find_excerpt(segments, /ip67|-20/i) }
      end
      if norm.include?('roaming')
        conds << { 'code' => 'MAND-ROAMING', 'label' => 'Hệ thống Wi-Fi hỗ trợ roaming mượt tập trung', 'source_excerpt' => find_excerpt(segments, /roaming/i) }
      end

      conds
    end

    def detect_ambiguous_phrases(norm)
      flags = []
      flags << 'Số lượng switch không xác định ("mấy con switch")' if norm =~ /(?:mấy|vài|ít)\s*(?:con|cái|bộ)?\s*switch/
      flags << 'Không nêu rõ số lượng Access Point và mật độ user Wi-Fi' if (norm.include?('wifi') || norm.include?('wi-fi')) && !(norm =~ /\d+\s*(?:access\s*point|ap\b|thiết\s*bị\s*wifi)/)
      flags << 'Đề cập Firewall nhưng không có số liệu user/throughput IPS/HA' if norm.include?('firewall') && !(norm =~ /ips|gbps|\bha\b|\d+\s*(?:firewall|bộ)/)
      flags << 'Không có mốc deadline hoặc thời gian triển khai cụ thể' if !(norm =~ /\d+\s*(?:tuần|ngày|tháng)|\d{1,2}\/\d{1,2}\/\d{4}/)
      flags
    end

    def find_excerpt(segments, regex)
      seg = segments.find { |s| s =~ regex }
      seg ? seg[0, 160] : ''
    end

    def evaluate_completeness(extracted, raw_text)
      missing = []
      items = extracted['items'] || []

      if items.empty?
        missing << {
          'field' => 'Danh sách hạng mục thiết bị/dịch vụ',
          'severity' => 'BLOCKING',
          'reason' => 'Không trích xuất được hạng mục thiết bị mạng hoặc dịch vụ cụ thể từ văn bản.',
          'question_for_customer' => 'Vui lòng cung cấp danh mục thiết bị cần trang bị (Switch, Firewall, Wi-Fi) và số lượng dự kiến cho từng hạng mục.'
        }
      end

      items.each do |it|
        if it['quantity'].nil? || it['quantity_ambiguous']
          missing << {
            'field' => "Số lượng hạng mục: #{it['name']}",
            'severity' => 'BLOCKING',
            'reason' => "Hồ sơ chỉ mô tả chung chung (\"#{it['source_excerpt'][0, 80]}...\"), chưa có số lượng chính xác để định giá và kiểm tra tồn kho.",
            'question_for_customer' => "Cho hạng mục #{it['name']}, Quý khách cần chính xác bao nhiêu thiết bị/đơn vị?"
          }
        end

        if it['spec_ambiguous']
          missing << {
            'field' => "Thông số kỹ thuật: #{it['name']}",
            'severity' => 'BLOCKING',
            'reason' => 'Thiếu thông số bắt buộc (ví dụ: số port 24/48, cần PoE không, thông lượng IPS Firewall hoặc mức chịu tải user) — dễ dẫn đến chọn sai gói giá thấp không đủ chức năng.',
            'question_for_customer' => "Vui lòng xác nhận thông số kỹ thuật tối thiểu cho #{it['name']} (số port, nhu cầu cấp nguồn PoE, số user đồng thời hoặc thông lượng IPS/HA)."
          }
        end
      end

      deadline = extracted['deadline'] || {}
      if deadline['duration_days'].nil? && deadline['target_date'].nil?
        missing << {
          'field' => 'Thời hạn triển khai (Deadline)',
          'severity' => 'BLOCKING',
          'reason' => 'Chưa có thời hạn hoàn thành/nghiệm thu cụ thể (chỉ nêu "sớm" hoặc bỏ trống), Bộ phận Vận hành không thể xếp lịch đội kỹ thuật.',
          'question_for_customer' => 'Quý khách dự kiến ngày hoàn tất triển khai & nghiệm thu (Go-live) là khi nào (hoặc trong bao nhiêu tuần kể từ ngày ký)?'
        }
      end

      norm = raw_text.to_s.downcase
      unless norm.include?('bảo trì') || norm.include?('sla') || norm.include?('bảo hành')
        missing << {
          'field' => 'Yêu cầu bảo trì & SLA vận hành',
          'severity' => 'WARNING',
          'reason' => 'Chưa nêu rõ gói bảo trì 8x5 hay 24x7 (SLA 4h/8h) sau nghiệm thu.',
          'question_for_customer' => 'Quý khách có yêu cầu gói bảo trì định kỳ 8x5 (SLA 8h) hay trực hỗ trợ 24x7 (SLA 4h) không?'
        }
      end

      budget = extracted['budget'] || {}
      if budget['amount_vnd'].nil?
        missing << {
          'field' => 'Ngân sách dự kiến',
          'severity' => 'WARNING',
          'reason' => 'Chưa có ngân sách trần để đối chiếu phương án tối ưu.',
          'question_for_customer' => 'Quý khách có thể chia sẻ khung ngân sách dự kiến để Thiên Minh tư vấn cấu hình phù hợp nhất?'
        }
      end

      blocking_count = missing.count { |m| m['severity'] == 'BLOCKING' }
      warning_count = missing.count { |m| m['severity'] == 'WARNING' }
      score = [100 - (blocking_count * 22) - (warning_count * 8), 10].max
      is_complete = blocking_count == 0

      email_draft = if is_complete
                      nil
                    else
                      build_clarification_email(extracted['customer_name'], missing)
                    end

      {
        'is_complete' => is_complete,
        'decision' => is_complete ? 'CÓ ĐỦ THÔNG TIN' : 'KHÔNG ĐỦ THÔNG TIN',
        'completeness_score' => score,
        'blocking_count' => blocking_count,
        'warning_count' => warning_count,
        'missing_fields' => missing,
        'clarification_email_draft' => email_draft
      }
    end

    def build_clarification_email(customer_name, missing)
      questions = missing.each_with_index.map do |m, idx|
        "#{idx + 1}. [#{m['severity'] == 'BLOCKING' ? 'Bắt buộc' : 'Khuyến nghị'}] #{m['question_for_customer']}"
      end.join("\n")

      <<~EMAIL
        Kính gửi Quý khách hàng #{customer_name},

        Cảm ơn Quý khách đã gửi yêu cầu chào giá tới Công ty Thiên Minh. Để đảm bảo phương án kỹ thuật chính xác, đủ chức năng, đúng tiến độ và không phát sinh chi phí ngoài dự kiến, Bộ phận Kinh doanh & Kỹ thuật kính nhờ Quý khách xác nhận bổ sung một số thông tin sau trước khi lập bản chào giá chính thức:

        #{questions}

        Ngay khi nhận được phản hồi của Quý khách, Thiên Minh sẽ hoàn tất hồ sơ đề xuất và gửi bản chào giá chi tiết trong thời gian sớm nhất.

        Trân trọng,
        Phòng Kinh doanh - Công ty Thiên Minh
      EMAIL
    end
  end
end
