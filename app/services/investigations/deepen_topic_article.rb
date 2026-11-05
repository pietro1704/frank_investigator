module Investigations
  class DeepenTopicArticle
    class Conflict < StandardError; end
    class Unavailable < StandardError; end
    Result = Data.define(:investigation, :delivery_deferred)

    def self.generation(topic)
      Digest::SHA256.hexdigest(topic.run_token)
    end

    def self.call(topic:, generation:, source_id:, starter: EnsureStarted)
      link = nil
      topic.with_lock do
        raise Conflict unless topic.completed? && generation.is_a?(String) && source_id.is_a?(String) &&
          ActiveSupport::SecurityUtils.secure_compare(self.generation(topic), generation)
        document = Array(topic.discovery["documents"]).find { |item| item["id"] == source_id }
        raise Conflict unless Array(topic.discovery["news_ids"]).include?(source_id) && document&.fetch("kind", nil) == "news_article"
        url = UrlNormalizer.call(document.fetch("url"))
        link = topic.topic_analysis_links.for_run(topic.run_token).find_by(source_id:)
        raise Conflict if link && (link.source_url != url || link.investigation&.normalized_url != url)
        investigation = starter.call(submitted_url: url, auto_submit_limit: 0)
        raise Conflict unless investigation.normalized_url == url
        link ||= topic.topic_analysis_links.create!(run_token: topic.run_token, source_id:, source_url: url, investigation:)
        raise Conflict unless link.investigation_id == investigation.id
      end
      Result.new(investigation: link.investigation, delivery_deferred: false)
    rescue Conflict, UrlNormalizer::InvalidUrlError, UrlClassifier::RejectedUrlError
      raise
    rescue StandardError => error
      # EnsureStarted dispatches after the enclosing transaction commits. A failed
      # adapter must not lose that durable link/intent or create another analysis.
      committed = TopicAnalysisLink.find_by(id: link&.id, topic_investigation_id: topic.id, run_token: topic.run_token, source_id:)
      if committed&.investigation && committed.investigation.normalized_url == committed.source_url
        Rails.logger.warn("Topic article delivery deferred (#{error.class.name})")
        Result.new(investigation: committed.investigation, delivery_deferred: true)
      else
        raise Unavailable
      end
    end
  end
end
