module Investigations
  class TopicResearchFingerprint
    def self.discovery(discovery)
      call(discovery.slice("question", "scope", "plan", "documents", "news_ids", "full_analyses"))
    end

    def self.call(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def self.canonical(value)
      case value
      when Hash
        value.except("checked_at").sort.to_h.transform_values { |item| canonical(item) }
      when Array
        value.map { |item| canonical(item) }
      else
        value
      end
    end
    private_class_method :canonical
  end
end
