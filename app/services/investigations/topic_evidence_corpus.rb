module Investigations
  # The same citable identities are given to the model and checked on return.
  class TopicEvidenceCorpus
    KINDS = %w[news_article producer_publication].freeze

    def self.call(discovery, supplemental: false)
      candidates = discovery.fetch("documents").deep_dup
      if supplemental
        candidates += discovery.fetch("full_analyses", []).select { |item| item["status"] == "ready" }
          .flat_map { |item| Array(item["evidence_documents"]) }.first(48)
      end
      by_id = {}
      identities = {}
      candidates.each do |item|
        raise TopicAssessment::InvalidResponse unless item.is_a?(Hash) && item["id"].is_a?(String) && item["body"].is_a?(String) && item["url"].is_a?(String) && item["title"].is_a?(String)
        previous = identities[item["id"]]
        if previous
          raise TopicAssessment::InvalidResponse unless previous.slice("url", "body", "kind") == item.slice("url", "body", "kind")
          next
        end
        identities[item["id"]] = item
        next unless KINDS.include?(item["kind"]) && item["body"].present?
        next if by_id.size >= 40
        by_id[item["id"]] = item
      end
      raise TopicAssessment::InvalidResponse if by_id.empty?
      by_id.values
    end
  end
end
