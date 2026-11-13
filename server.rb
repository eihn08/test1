# encoding: utf-8
# frozen_string_literal: true

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require 'webrick'
require 'json'
require 'uri'
require_relative 'lib/store'
require_relative 'lib/llm_client'
require_relative 'lib/agent_orchestrator'
require_relative 'lib/agent_copilot'

ROOT_DIR = File.expand_path(__dir__)
DATA_DIR = File.join(ROOT_DIR, 'data')
PUBLIC_DIR = File.join(ROOT_DIR, 'public')
PORT = (ENV['PORT'] || 8787).to_i
HOST = ENV['HOST'] || '127.0.0.1'

store = ThienMinh::Store.new(DATA_DIR)
orchestrator = ThienMinh::AgentOrchestrator.new(store)
copilot = ThienMinh::AgentCopilot.new(store)

server = WEBrick::HTTPServer.new(
  Port: PORT,
  BindAddress: HOST,
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)

def json_response(res, status, payload)
  res.status = status
  res['Content-Type'] = 'application/json; charset=utf-8'
  res['Cache-Control'] = 'no-store'
  res.body = JSON.generate(payload)
end

def parse_body(req)
  raw = req.body.to_s.force_encoding('UTF-8')
  return {} if raw.strip.empty?

  JSON.parse(raw)
end

def mask_settings(s)
  key = s['api_key'].to_s
  masked = key.empty? ? '' : "#{key[0, 4]}...#{key[-4, 4]}"
  {
    'engine_mode' => s['engine_mode'],
    'provider' => s['provider'],
    'model' => s['model'],
    'temperature' => s['temperature'],
    'has_api_key' => !key.empty?,
    'api_key_masked' => masked
  }
end

MIME_TYPES = {
  '.html' => 'text/html; charset=utf-8',
  '.css' => 'text/css; charset=utf-8',
  '.js' => 'application/javascript; charset=utf-8',
  '.json' => 'application/json; charset=utf-8',
  '.svg' => 'image/svg+xml',
  '.png' => 'image/png',
  '.jpg' => 'image/jpeg'
}.freeze

server.mount_proc '/' do |req, res|
  path = URI.decode_www_form_component(req.path)

  begin
    # API Router
    if path.start_with?('/api/')
      if req.request_method == 'GET' && path == '/api/health'
        json_response(res, 200, { 'ok' => true, 'service' => 'Thien Minh RFP AI Agent', 'port' => PORT })

      elsif req.request_method == 'GET' && path == '/api/dashboard'
        json_response(res, 200, {
          'summary' => orchestrator.dashboard_summary,
          'cases' => store.all_cases
        })

      elsif req.request_method == 'GET' && path == '/api/cases'
        json_response(res, 200, { 'cases' => store.all_cases })

      elsif req.request_method == 'POST' && path == '/api/cases'
        body = parse_body(req)
        raise 'Vui lòng nhập nội dung yêu cầu chào giá (raw_text)' if body['raw_text'].to_s.strip.empty?

        created = orchestrator.create_case(body)
        json_response(res, 201, { 'case' => created, 'summary' => orchestrator.dashboard_summary })

      elsif path =~ %r{^/api/cases/([^/]+)$}
        case_id = Regexp.last_match(1)
        if req.request_method == 'GET'
          rec = store.find_case(case_id)
          if rec
            json_response(res, 200, { 'case' => rec })
          else
            json_response(res, 404, { 'error' => "Không tìm thấy hồ sơ #{case_id}" })
          end
        elsif req.request_method == 'DELETE'
          deleted = store.delete_case(case_id)
          json_response(res, deleted ? 200 : 404, { 'ok' => deleted })
        else
          json_response(res, 405, { 'error' => 'Method not allowed' })
        end

      elsif req.request_method == 'POST' && path =~ %r{^/api/cases/([^/]+)/run$}
        case_id = Regexp.last_match(1)
        body = parse_body(req)
        override_disc = body['override_discount_pct']
        updated = orchestrator.run_pipeline(case_id, override_discount_pct: override_disc)
        json_response(res, 200, { 'case' => updated, 'summary' => orchestrator.dashboard_summary })

      elsif req.request_method == 'POST' && path =~ %r{^/api/cases/([^/]+)/clarify$}
        case_id = Regexp.last_match(1)
        body = parse_body(req)
        reply = body['customer_reply'].to_s.strip
        raise 'Vui lòng nhập nội dung khách hàng bổ sung' if reply.empty?

        updated = orchestrator.submit_clarification(case_id, reply, body['actor'] || 'Nhân viên Kinh doanh')
        json_response(res, 200, { 'case' => updated, 'summary' => orchestrator.dashboard_summary })

      elsif req.request_method == 'POST' && path =~ %r{^/api/cases/([^/]+)/tech-survey$}
        case_id = Regexp.last_match(1)
        body = parse_body(req)
        updated = orchestrator.survey_tech_signoff(
          case_id,
          body['surveyor_name'] || 'Kỹ sư Pre-sales & PMO Vận hành',
          body['decision'] || 'CHẤP THUẬN PHƯƠNG ÁN ĐẶC THÙ',
          body['notes'] || ''
        )
        json_response(res, 200, { 'case' => updated, 'summary' => orchestrator.dashboard_summary })

      elsif req.request_method == 'POST' && path =~ %r{^/api/cases/([^/]+)/escalate$}
        case_id = Regexp.last_match(1)
        body = parse_body(req)
        updated = orchestrator.approve_escalation(
          case_id,
          body['approver_name'] || 'Lãnh đạo Thiên Minh',
          body['role'] || 'Trưởng phòng / Ban Giám đốc',
          body['decision'] || 'APPROVE',
          body['comment'] || '',
          body['adjusted_discount_pct']
        )
        json_response(res, 200, { 'case' => updated, 'summary' => orchestrator.dashboard_summary })

      elsif req.request_method == 'POST' && path =~ %r{^/api/cases/([^/]+)/signoff$}
        case_id = Regexp.last_match(1)
        body = parse_body(req)
        updated = orchestrator.submit_dept_signoff(
          case_id,
          body['department'],
          body['reviewer_name'] || 'Thành viên thẩm định',
          body['action'] || 'APPROVE',
          body['note'] || ''
        )
        json_response(res, 200, { 'case' => updated, 'summary' => orchestrator.dashboard_summary })

      elsif req.request_method == 'POST' && path =~ %r{^/api/cases/([^/]+)/publish$}
        case_id = Regexp.last_match(1)
        body = parse_body(req)
        updated = orchestrator.publish_quotation(case_id, body['publisher_name'] || 'Trưởng phòng Kinh doanh')
        json_response(res, 200, { 'case' => updated, 'summary' => orchestrator.dashboard_summary })

      elsif req.request_method == 'GET' && path == '/api/knowledge'
        json_response(res, 200, {
          'catalog' => store.catalog,
          'capacity_schedule' => store.capacity_schedule,
          'policies' => store.policies,
          'sample_rfps' => store.sample_rfps
        })

      elsif req.request_method == 'PUT' && path == '/api/knowledge/schedule'
        body = parse_body(req)
        store.update_capacity_schedule(body)
        json_response(res, 200, { 'ok' => true, 'capacity_schedule' => store.capacity_schedule })

      elsif req.request_method == 'GET' && path == '/api/settings'
        json_response(res, 200, { 'settings' => mask_settings(store.settings) })

      elsif req.request_method == 'PUT' && path == '/api/settings'
        body = parse_body(req)
        patch = {}
        patch['engine_mode'] = body['engine_mode'] if body.key?('engine_mode')
        patch['provider'] = body['provider'] if body.key?('provider')
        patch['model'] = body['model'] if body.key?('model')
        patch['temperature'] = body['temperature'].to_f if body.key?('temperature')
        if body.key?('api_key') && !body['api_key'].to_s.strip.empty?
          patch['api_key'] = body['api_key'].to_s.strip
        elsif body['clear_api_key']
          patch['api_key'] = ''
        end
        updated = store.update_settings(patch)
        json_response(res, 200, { 'settings' => mask_settings(updated) })

      elsif req.request_method == 'POST' && path == '/api/settings/test'
        llm = ThienMinh::LLMClient.new(store.settings)
        json_response(res, 200, llm.test_connection)

      elsif req.request_method == 'POST' && path == '/api/agent/chat'
        body = parse_body(req)
        raise 'Vui lòng nhập nội dung câu hỏi cho AI Agent' if body['message'].to_s.strip.empty?

        json_response(res, 200, copilot.reply(message: body['message'], case_id: body['case_id']))

      elsif req.request_method == 'POST' && path == '/api/demo/reset'
        store.reset_demo!
        orchestrator.seed_initial_cases_if_needed!
        json_response(res, 200, {
          'ok' => true,
          'summary' => orchestrator.dashboard_summary,
          'cases' => store.all_cases
        })

      else
        json_response(res, 404, { 'error' => "Endpoint không tồn tại: #{req.request_method} #{path}" })
      end

    else
      # Static frontend files
      rel = path == '/' ? 'index.html' : path.sub(%r{^/+}, '')
      clean_path = File.expand_path(rel, PUBLIC_DIR)
      unless clean_path.start_with?(PUBLIC_DIR) && File.file?(clean_path)
        res.status = 404
        res['Content-Type'] = 'text/plain; charset=utf-8'
        res.body = '404 Not Found'
      else
        ext = File.extname(clean_path).downcase
        res.status = 200
        res['Content-Type'] = MIME_TYPES[ext] || 'application/octet-stream'
        res.body = File.binread(clean_path)
      end
    end
  rescue StandardError => e
    json_response(res, 400, { 'error' => e.message })
  end
end

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }

puts "=============================================================="
puts " Thiên Minh AI Agent - Đánh giá Yêu cầu Chào giá (RFP/RFQ)"
puts " Localhost URL: http://#{HOST}:#{PORT}"
puts " Nhấn Ctrl+C để dừng server."
puts "=============================================================="
$stdout.flush

server.start
