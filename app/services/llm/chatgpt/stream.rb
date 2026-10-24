module Llm
  module Chatgpt
    # A delta is provisional. Only a terminal completed event can publish a result.
    class Stream
      def initialize
        @buffer = +""
        @data = []
      end

      def feed(chunk)
        @buffer << chunk
        while (index = @buffer.index("\n"))
          line = @buffer.slice!(0..index).delete_suffix("\n").delete_suffix("\r")
          if line.empty?
            dispatch unless @data.empty?
            @data.clear
          elsif line.start_with?("data:")
            @data << line.delete_prefix("data:").delete_prefix(" ")
          end
        end
      end

      def completed_response
        raise Error.new("interrupted_stream") unless @completed
        @completed
      end

      private

      def dispatch
        raw = @data.join("\n")
        return if raw == "[DONE]"
        event = JSON.parse(raw)
        case event["type"]
        when "response.completed"
          raise Error.new("incomplete_response") unless event.dig("response", "status") == "completed"
          @completed = event.fetch("response")
        when "response.failed", "error"
          code = event.dig("response", "error", "code") || event["code"]
          code = "response_failed" unless code.to_s.match?(/\A[a-zA-Z0-9_]{1,100}\z/)
          raise Error.new(code)
        when "response.incomplete", "response.cancelled"
          raise Error.new("incomplete_response")
        end
      rescue JSON::ParserError
        raise Error.new("invalid_stream_event")
      end
    end
  end
end
