module Investigations
  class DiscoverTopicJob < ApplicationJob
    queue_as :fetch

    def perform(topic_id, run_token)
      topic = TopicInvestigation.find_by(id: topic_id)
      return unless topic
      lease_token = topic.claim_execution!(run_token:)
      return unless lease_token

      result = TopicDiscovery.call(question: topic.question,
        cancelled: -> { !topic.execution_current?(run_token:, lease_token:) },
        on_progress: lambda { |stage, snapshot|
          persisted = topic.checkpoint!(run_token:, lease_token:, stage:, discovery: snapshot)
          raise TopicDiscovery::Cancelled unless persisted
        })
      topic.finish_discovery!(run_token:, lease_token:, discovery: result)
    rescue TopicDiscovery::Cancelled
      topic.fail_execution!(run_token:, lease_token:, code: "interrupted") if topic && lease_token
    rescue StandardError => error
      topic.fail_execution!(run_token:, lease_token:, code: error_code(error)) if topic && lease_token
      Rails.logger.warn("Topic research failed (#{error.class.name})")
    end

    private

    def error_code(error)
      case error
      when TopicInvestigation::InvalidDiscovery, TopicDiscovery::InvalidResponse
        "invalid_result"
      when TopicDiscovery::Unavailable
        "provider_unavailable"
      when Llm::Chatgpt::Error
        error.code == "subscription_sharing_usage_limit_exceeded" ? "usage_limit" : "provider_unavailable"
      else
        "research_failed"
      end
    end
  end
end
