module Investigations
  class AssessTopicJob < ApplicationJob
    queue_as :default

    def perform(topic_id, run_token)
      topic = TopicInvestigation.find_by(id: topic_id)
      return unless topic
      token = topic.claim_assessment!(run_token:)
      return unless token
      result = TopicAssessment.call(discovery: topic.discovery,
        cancelled: -> { !topic.execution_current?(run_token:, lease_token: token, phase: "assessing") })
      topic.finish_assessment!(run_token:, lease_token: token, report: result)
    rescue TopicDiscovery::Cancelled
      topic.fail_execution!(run_token:, lease_token: token, code: "interrupted", phase: "assessing") if topic && token
    rescue StandardError => error
      code = case error
      when TopicAssessment::InvalidResponse, TopicDiscovery::InvalidResponse, TopicInvestigation::InvalidReport
        "invalid_result"
      when TopicDiscovery::Unavailable
        "provider_unavailable"
      when Llm::Chatgpt::Error
        error.code == "subscription_sharing_usage_limit_exceeded" ? "usage_limit" : "provider_unavailable"
      else
        "research_failed"
      end
      topic.fail_execution!(run_token:, lease_token: token, code:, phase: "assessing") if topic && token
      Rails.logger.warn("Topic assessment failed (#{error.class.name})")
    end
  end
end
