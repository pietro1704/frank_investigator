module Investigations
  class StartTopicAnalysesJob < ApplicationJob
    queue_as :default

    def perform(topic_id, run_token)
      topic = TopicInvestigation.find_by(id: topic_id)
      return unless topic&.full_analysis_required? && !topic.discovery["analysis_phase_complete"]
      lease = topic.claim_assessment!(run_token:)
      return unless lease
      LinkTopicAnalyses.call(topic:, run_token:, lease_token: lease)
      if topic.wait_for_analyses!(run_token:, lease_token: lease)
        ActiveRecord.after_all_transactions_commit { TopicResearchDelivery.dispatch(topic_id, run_token) }
      end
    rescue StandardError => error
      topic.fail_execution!(run_token:, lease_token: lease, phase: "assessing", code: "analysis_submission_failed") if topic && lease
      Rails.logger.warn("Topic analysis submission failed (#{error.class.name})")
    end
  end
end
