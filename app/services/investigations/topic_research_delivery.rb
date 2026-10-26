module Investigations
  # The queued row is durable intent. A short delivery lease fences competing
  # dispatchers; a separate generation token fences jobs from previous retries.
  class TopicResearchDelivery
    def self.dispatch(id, run_token)
      topic = TopicInvestigation.find_by(id:, run_token:, status: "queued")
      return false unless topic

      token = nil
      topic.with_lock do
        return false unless topic.queued? && topic.run_token == run_token
        return false if topic.lease_expires_at&.future?
        token = SecureRandom.uuid
        topic.update!(lease_token: token, lease_expires_at: TopicInvestigation::LEASE_FOR.from_now, error_code: nil)
      end
      job = DiscoverTopicJob.perform_later(id, run_token)
      return true if job && job.successfully_enqueued?

      release(id, run_token, token)
      false
    rescue StandardError
      release(id, run_token, token) if token
      false
    end

    def self.release(id, run_token, token)
      TopicInvestigation.where(id:, run_token:, lease_token: token, status: "queued").update_all(
        lease_token: nil, lease_expires_at: nil, error_code: "enqueue_failed", updated_at: Time.current
      )
    end
    private_class_method :release
  end
end
