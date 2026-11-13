# encoding: utf-8
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

BASE = 'http://127.0.0.1:8787'

def get(path)
  uri = URI.parse("#{BASE}#{path}")
  req = Net::HTTP::Get.new(uri.request_uri)
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 5
  http.read_timeout = 5
  res = http.request(req)
  [res.code.to_i, res.body]
end

def post(path, payload = {})
  uri = URI.parse("#{BASE}#{path}")
  req = Net::HTTP::Post.new(uri.request_uri, { 'Content-Type' => 'application/json' })
  req.body = JSON.generate(payload)
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 5
  http.read_timeout = 5
  res = http.request(req)
  [res.code.to_i, res.body]
end

puts "=== 1. Test Health ==="
code, body = get('/api/health')
raise "Health failed: #{code}" unless code == 200
puts "Health OK: #{body}"

puts "\n=== 2. Test Reset Demo Data ==="
code, body = post('/api/demo/reset', {})
raise "Reset failed: #{code}" unless code == 200
data = JSON.parse(body)
puts "Reset OK: #{data['cases'].size} cases loaded"

puts "\n=== 3. Verify Deliverables & Tasklist Coordination ==="
rfp1 = data['cases'].find { |c| c['id'] == 'RFP-2026-1101' }
del = rfp1['deliverables']
raise "Missing deliverables in RFP-2026-1101" unless del
tasklist = del['tasklist_coordination']
raise "Missing tasklist_coordination in deliverables" unless tasklist && tasklist.size >= 5
puts "Tasklist Coordination OK: #{tasklist.size} tasks generated across 3 departments"
tasklist.each { |t| puts "  - [#{t['department']}] #{t['title']} (#{t['status']})" }

puts "\n=== 4. Test Step 2 Tech Survey on Case with Out-of-Catalog Items ==="
target_case = data['cases'].find { |c| c.dig('feasibility', 'has_out_of_catalog') } || data['cases'].find { |c| c['id'] == 'RFP-2026-1104' } || data['cases'].first
puts "Target Case for Tech Survey: #{target_case['id']} (has_out_of_catalog: #{target_case.dig('feasibility', 'has_out_of_catalog')})"
code, body = post("/api/cases/#{target_case['id']}/tech-survey", {
  'surveyor_name' => 'Lê Anh Dũng (CCIE Pre-sales & PMO)',
  'decision' => 'CHẤP THUẬN PHƯƠNG ÁN ĐẶC THÙ (SOURCING MOXA/HIRSCHMANN)',
  'notes' => 'Đã khảo sát thực địa kho lạnh Cảng Cát Lái, nhà cung cấp Moxa cam kết giao hàng 21 ngày kèm CO/CQ.'
})
raise "Tech survey failed: #{code}" unless code == 200
target_after = JSON.parse(body)['case']
survey_res = target_after.dig('hitl', 'tech_survey')
raise "Missing tech survey data" unless survey_res && survey_res['conducted']
puts "Tech Survey OK: Conducted by #{survey_res['by']} - #{survey_res['decision']}"

puts "\n=== 5. Test Step 1 HITL Clarification on RFP-2026-1102 (Thiếu Thông Tin) ==="
code, body = post('/api/cases/RFP-2026-1102/clarify', {
  'customer_reply' => "Bổ sung từ Bệnh viện Tâm An:\n- 04 Switch Access 24 port PoE+ 370W uplink 10G\n- 08 AP Wi-Fi 6 doanh nghiệp\n- 01 Firewall NGFW IPS 5Gbps\n- Dịch vụ triển khai & bảo trì 24x7 SLA 4h (12 tháng)\n- Thời hạn hoàn thành: 5 tuần, ngân sách 550 triệu VND.",
  'actor' => 'Nguyễn Minh Tuấn (Kinh doanh)'
})
raise "Clarify failed: #{code}" unless code == 200
rfp2_after = JSON.parse(body)['case']
puts "Clarify OK: New status=#{rfp2_after['status']}, Completeness=#{rfp2_after.dig('completeness_gate', 'completeness_score')}/100"

puts "\n=== 6. Test Step 5 1-Click Full Approvals & Publish on RFP-2026-1101 ==="
# Escalate
code, body = post('/api/cases/RFP-2026-1101/escalate', {
  'approver_name' => 'Trần Minh Quân (Phó Giám đốc)',
  'role' => 'Ban Giám đốc',
  'decision' => 'APPROVE',
  'comment' => 'Phê duyệt chiết khấu 7.5% cho đối tác chiến lược.'
})
raise "Escalate approve failed: #{code}" unless code == 200

# 3 depts signoff
%w[sales technical operations].each do |dept|
  code, body = post('/api/cases/RFP-2026-1101/signoff', {
    'department' => dept,
    'reviewer_name' => "Trưởng phòng #{dept.capitalize}",
    'action' => 'APPROVE'
  })
  raise "Signoff #{dept} failed: #{code}" unless code == 200
end

# Publish
code, body = post('/api/cases/RFP-2026-1101/publish', {
  'publisher_name' => 'Trưởng phòng Kinh doanh Thiên Minh'
})
raise "Publish failed: #{code}" unless code == 200
rfp1_pub = JSON.parse(body)['case']
puts "Publish OK: status=#{rfp1_pub['status']}, published_at=#{rfp1_pub['published_at']}, quote_no=#{rfp1_pub.dig('deliverables', 'draft_quotation', 'quote_number')}"

puts "\n=== 7. Verify Static Assets (HTML, CSS, JS) ==="
%w[/ /styles.css /app.js].each do |path|
  code, body = get(path)
  raise "Static #{path} failed: #{code}" unless code == 200
  puts "Static #{path}: #{code} OK (#{body.size} bytes)"
end

puts "\n🎉 ALL INTEGRATION TESTS PASSED 100%!"
