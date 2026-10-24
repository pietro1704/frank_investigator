module Llm
  module Chatgpt
    class Chat
      Tokens = Struct.new(:input, :output)
      Result = Struct.new(:content, :tokens)

      def initialize(model:, credentials: Credentials.new)
        @model = model
        @credentials = credentials
      end

      def with_instructions(instructions)
        @instructions = instructions
        self
      end

      def with_schema(schema)
        @schema = schema.deep_stringify_keys
        self
      end

      def ask(prompt)
        payload = { model: @model, store: false, stream: true, input: [ { role: "user", content: prompt } ] }
        payload[:instructions] = @instructions if @instructions.present?
        if @schema
          payload[:text] = { format: { type: "json_schema", name: @schema.fetch("name"), schema: @schema.fetch("schema"), strict: true } }
        end
        parser = Stream.new
        access_token = @credentials.access_token
        Transport.new.stream(payload, bearer: access_token) { |chunk| parser.feed(chunk) }
        response = parser.completed_response
        text = Array(response["output"]).flat_map { |item| Array(item["content"]) }
          .select { |item| item["type"] == "output_text" }.map { |item| item.fetch("text") }.join
        raise Error.new("empty_response") if text.blank?
        content = @schema ? JSON.parse(text) : text
        usage = response.fetch("usage", {})
        Result.new(content, Tokens.new(usage["input_tokens"], usage["output_tokens"]))
      rescue JSON::ParserError
        raise Error.new("invalid_structured_response")
      rescue Error => error
        @credentials.pause_usage(access_token) if error.code == "subscription_sharing_usage_limit_exceeded" && access_token
        raise
      end
    end
  end
end
