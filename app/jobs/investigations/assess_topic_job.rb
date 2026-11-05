module Investigations
  class AssessTopicJob < ApplicationJob
    queue_as :default

    # A saved response crosses the same validation seam as a fresh model response.
    class RecordedAssessment
      def initialize(report)
        @raw = report.fetch("model_result")
      end

      def assess(discovery:)
        @raw.deep_dup
      end
    end

    def perform(topic_id, run_token)
      topic = TopicInvestigation.find_by(id: topic_id)
      return unless topic
      return if topic.full_analysis_required? && !topic.discovery["analysis_phase_complete"]
      token = topic.claim_assessment!(run_token:)
      return unless token
      cancelled = -> { !topic.execution_current?(run_token:, lease_token: token, phase: "assessing") }
      fingerprint = TopicResearchFingerprint.discovery(topic.discovery)
      state = topic.assessment_checkpoint.deep_dup
      unless state["version"] == 1 && state["run_token"] == run_token && state["discovery_fingerprint"] == fingerprint
        state = { "version" => 1, "run_token" => run_token, "discovery_fingerprint" => fingerprint }
      end
      options = { discovery: topic.discovery, cancelled: }
      options[:model] = RecordedAssessment.new(state["report"]) if state.dig("report", "model_result").is_a?(Hash)
      result = TopicAssessment.call(**options)
      state["report"] = result
      if topic.full_analysis_required?
        synthesizing = true
        return unless topic.checkpoint_assessment!(run_token:, lease_token: token, stage: "synthesizing", checkpoint: state)
        result = TopicSynthesis.call(discovery: topic.discovery, report: result, cancelled:,
          checkpoint: state.fetch("synthesis", {}), on_progress: lambda { |progress|
            state["synthesis"] = progress
            unless topic.checkpoint_assessment!(run_token:, lease_token: token, stage: "synthesizing", checkpoint: state)
              raise TopicDiscovery::Cancelled
            end
          })
      end
      topic.finish_assessment!(run_token:, lease_token: token, report: result)
    rescue TopicDiscovery::Cancelled
      topic.fail_execution!(run_token:, lease_token: token, code: "interrupted", phase: "assessing") if topic && token
    rescue StandardError => error
      code = case error
      when Timeout::Error
        synthesizing ? "synthesis_timeout" : "assessment_timeout"
      when TopicAssessment::InvalidResponse, TopicDiscovery::InvalidResponse, TopicInvestigation::InvalidReport
        synthesizing ? "synthesis_invalid" : "invalid_result"
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
