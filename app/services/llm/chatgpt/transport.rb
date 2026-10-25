require "net/http"
require "json"

module Llm
  module Chatgpt
    # Fixed public endpoints only. Never forwards credentials across redirects.
    class Transport
      def json(url, form: nil, bearer: nil)
        uri = URI(url)
        request = form ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
        request.set_form_data(form) if form
        request["Authorization"] = "Bearer #{bearer}" if bearer
        request["Accept"] = "application/json"
        response = connection(uri) { |http| http.request(request) }
        check!(response.code.to_i, response.body, response["x-request-id"])
        response.body.to_s.empty? ? {} : JSON.parse(response.body)
      rescue JSON::ParserError
        raise Error.new("invalid_json")
      end

      def stream(payload, bearer:)
        uri = URI("https://api.openai.com/v1/responses")
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{bearer}"
        request["Content-Type"] = "application/json"
        request["Accept"] = "text/event-stream"
        request.body = JSON.generate(payload)
        connection(uri) do |http|
          http.request(request) do |response|
            check!(response.code.to_i, response.body, response["x-request-id"]) unless response.is_a?(Net::HTTPSuccess)
            response.read_body { |chunk| yield chunk }
          end
        end
      end

      private

      def connection(uri, &block)
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15,
          read_timeout: ENV.fetch("LLM_TIMEOUT_SECONDS", 120).to_i, &block)
      end

      def check!(status, body, request_id = nil)
        return if (200...300).cover?(status)
        data = JSON.parse(body.to_s) rescue {}
        # Server messages may contain submitted text or credentials. Keep codes only.
        error = data.is_a?(Hash) ? data["error"] : nil
        code = error.is_a?(Hash) ? error["code"].to_s : error.to_s
        code = "http_error" unless code.match?(/\A[a-zA-Z0-9_]{1,100}\z/)
        raise Error.new(code, status:, request_id:, response_body: body)
      end
    end
  end
end
