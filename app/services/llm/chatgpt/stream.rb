module Llm
  module Chatgpt
    # A delta is provisional. Only a terminal completed event can publish a result.
    class Stream
      def initialize
        @buffer = +""
        @data = []
        @done_items = {}
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
        when "response.output_item.done"
          index = event["output_index"]
          raise Error.new("invalid_output_index") unless index.is_a?(Integer) && index >= 0
          @done_items[index] = event.fetch("item")
        when "response.completed"
          raise Error.new("incomplete_response") unless event.dig("response", "status") == "completed"
          @completed = event.fetch("response")
          # With store:false, the terminal event can omit the already-streamed
          # output. Keep done items provisional until this terminal success.
          if Array(@completed["output"]).empty?
            @completed = @completed.merge("output" => @done_items.sort_by(&:first).map(&:last))
          end
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
