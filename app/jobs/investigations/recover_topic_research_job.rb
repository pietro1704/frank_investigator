module Investigations
  # Recover lost queue deliveries; expired in-flight work is failed visibly and
  # requires an explicit retry, rather than automatically spending more usage.
  class RecoverTopicResearchJob < ApplicationJob
    queue_as :default
    LIMIT = 100

    def perform
      now = Time.current
      expired = TopicInvestigation.where(status: %w[researching assessing])
        .where("lease_expires_at IS NULL OR lease_expires_at <= ?", now).order(:id).limit(LIMIT)
      expired.pluck(:id, :run_token, :lease_token).each do |id, run_token, lease_token|
        TopicInvestigation.where(id:, run_token:, lease_token:, status: %w[researching assessing])
          .where("lease_expires_at IS NULL OR lease_expires_at <= ?", now).update_all(
            status: "failed", stage: "failed", error_code: "interrupted", finished_at: now,
            lease_token: nil, lease_expires_at: nil, updated_at: now)
      end
      queued = TopicInvestigation.where(status: %w[queued awaiting_assessment])
        .where("lease_expires_at IS NULL OR lease_expires_at <= ?", now).order(:id).limit(LIMIT)
      queued.pluck(:id, :run_token).each { |id, token| TopicResearchDelivery.dispatch(id, token) }
    end
  end
end
