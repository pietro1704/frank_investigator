module Llm
  module Chatgpt
    class Error < StandardError
      attr_reader :code, :status, :request_id, :response_body

      def initialize(code, status: nil, request_id: nil, response_body: nil)
        @code = code.to_s
        @status = status
        @request_id = request_id
        @response_body = response_body # Diagnostic data only; excluded from message/logs.
        super("ChatGPT plan: #{@code}#{" (HTTP #{status})" if status}. Check the connection and ChatGPT Settings > Usage.")
      end
    end
  end
end
