module Investigations
  # Per-run links share full URL investigations without changing their groups.
  # EnsureStarted retains the existing durable, post-commit kickoff delivery.
  class LinkTopicAnalyses
    def self.call(topic:, run_token:, starter: EnsureStarted)
      topic.with_lock do
        return [] unless topic.run_token == run_token && topic.awaiting_assessment?
        discovery = topic.discovery
        ids = discovery["news_ids"]
        documents = Array(discovery["documents"])
        by_id = documents.index_by { |item| item["id"] }
        unless ids.is_a?(Array) && ids.size.between?(1, TopicPlan::MAX_NEWS) && ids.uniq == ids &&
            ids.all? { |id| by_id[id]&.fetch("kind", nil) == "news_article" }
          raise TopicInvestigation::InvalidDiscovery
        end
        sources = ids.map do |id|
          document = by_id.fetch(id)
          [ id, UrlNormalizer.call(document.fetch("url")) ]
        end
        sources.each do |id, url|
          next if topic.topic_analysis_links.for_run(run_token).exists?(source_id: id)
          investigation = starter.call(submitted_url: url)
          topic.topic_analysis_links.create!(run_token:, source_id: id, source_url: url, investigation:)
        end
        topic.topic_analysis_links.for_run(run_token).order(:id).to_a
      end
    end
  end
end
