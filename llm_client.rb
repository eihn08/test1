# encoding: utf-8
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'openssl'

module ThienMinh
  class LLMClient
    def initialize(settings)
      @settings = settings || {}
    end

    def mode
      @settings['engine_mode'] || 'hybrid'
    end

    def api_key
      key = (@settings['api_key'] || '').strip
      return ENV['GEMINI_API_KEY'].to_s.strip if key.empty? && provider == 'gemini' && !ENV['GEMINI_API_KEY'].to_s.strip.empty?
      return ENV['OPENAI_API_KEY'].to_s.strip if key.empty? && provider == 'openai' && !ENV['OPENAI_API_KEY'].to_s.strip.empty?

      key
    end

    def provider
      (@settings['provider'] || 'gemini').downcase
    end

    def model
      m = (@settings['model'] || '').strip
      return m unless m.empty?

      provider == 'openai' ? 'gpt-4o-mini' : 'gemini-2.5-flash'
    end

    def llm_enabled?
      return false if mode == 'offline'

      !api_key.empty?
    end

    def test_connection
      if api_key.empty?
        return {
          'ok' => false,
          'provider' => provider,
          'model' => model,
          'message' => 'Chưa cấu hình API Key. Hệ thống đang sẵn sàng chạy bằng Offline Heuristic Engine.'
        }
      end

      res = generate_json(
        'Trả về JSON hợp lệ với đúng key "status": "ok" và "greeting": "Xin chào từ AI Engine".',
        'Kiểm tra kết nối'
      )
      if res['ok']
        {
          'ok' => true,
          'provider' => provider,
          'model' => model,
          'message' => "Kết nối thành công tới #{provider.upcase} (#{model})!",
          'sample' => res['data']
        }
      else
        {
          'ok' => false,
          'provider' => provider,
          'model' => model,
          'message' => "Lỗi kết nối #{provider.upcase}: #{res['error']}"
        }
      end
    end

    def generate_json(system_prompt, user_prompt)
      unless llm_enabled?
        return { 'ok' => false, 'error' => 'LLM chưa bật hoặc thiếu API key', 'used_llm' => false }
      end

      raw_text = if provider == 'openai'
                   call_openai(system_prompt, user_prompt)
                 else
                   call_gemini(system_prompt, user_prompt)
                 end

      parsed = parse_json_block(raw_text)
      {
        'ok' => true,
        'used_llm' => true,
        'provider' => provider,
        'model' => model,
        'data' => parsed
      }
    rescue StandardError => e
      {
        'ok' => false,
        'used_llm' => false,
        'provider' => provider,
        'model' => model,
        'error' => e.message
      }
    end

    private

    def call_gemini(system_prompt, user_prompt)
      uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{URI.encode_www_form_component(model)}:generateContent?key=#{URI.encode_www_form_component(api_key)}")
      payload = {
        'systemInstruction' => {
          'parts' => [{ 'text' => system_prompt }]
        },
        'contents' => [
          {
            'role' => 'user',
            'parts' => [{ 'text' => user_prompt }]
          }
        ],
        'generationConfig' => {
          'temperature' => (@settings['temperature'] || 0.2).to_f,
          'responseMimeType' => 'application/json'
        }
      }

      body = post_json(uri, payload, {})
      json = JSON.parse(body)
      if json['error']
        raise(json['error']['message'] || 'Gemini API error')
      end

      candidates = json['candidates'] || []
      text = candidates.dig(0, 'content', 'parts', 0, 'text')
      raise 'Gemini không trả về nội dung' if text.nil? || text.strip.empty?

      text
    end

    def call_openai(system_prompt, user_prompt)
      uri = URI('https://api.openai.com/v1/chat/completions')
      payload = {
        'model' => model,
        'temperature' => (@settings['temperature'] || 0.2).to_f,
        'response_format' => { 'type' => 'json_object' },
        'messages' => [
          { 'role' => 'system', 'content' => system_prompt },
          { 'role' => 'user', 'content' => user_prompt }
        ]
      }
      headers = { 'Authorization' => "Bearer #{api_key}" }
      body = post_json(uri, payload, headers)
      json = JSON.parse(body)
      if json['error']
        raise(json['error']['message'] || 'OpenAI API error')
      end

      text = json.dig('choices', 0, 'message', 'content')
      raise 'OpenAI không trả về nội dung' if text.nil? || text.strip.empty?

      text
    end

    def post_json(uri, payload, extra_headers)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 10
      http.read_timeout = 35

      req = Net::HTTP::Post.new(uri.request_uri)
      req['Content-Type'] = 'application/json; charset=utf-8'
      extra_headers.each { |k, v| req[k] = v }
      req.body = JSON.generate(payload)

      resp = http.request(req)
      resp_body = resp.body.to_s.force_encoding('UTF-8')
      unless resp.is_a?(Net::HTTPSuccess)
        raise "HTTP #{resp.code}: #{resp_body[0, 300]}"
      end

      resp_body
    end

    def parse_json_block(text)
      cleaned = text.strip
      if cleaned =~ /```(?:json)?\s*\n?(.*?)\n?```/m
        cleaned = Regexp.last_match(1).strip
      end
      JSON.parse(cleaned)
    end
  end
end

