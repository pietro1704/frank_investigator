module Investigations
  # The queued row is durable intent. A short delivery lease fences competing
  # dispatchers; a separate generation token fences jobs from previous retries.
  class TopicResearchDelivery
    DELIVERABLE = %w[queued awaiting_assessment awaiting_analyses].freeze

    def self.dispatch(id, run_token)
      topic = TopicInvestigation.find_by(id:, run_token:, status: DELIVERABLE)
      return false unless topic

      token = nil
      topic.with_lock do
        return false unless topic.status.in?(DELIVERABLE) && topic.run_token == run_token
        return false if topic.lease_expires_at&.future?
        token = SecureRandom.uuid
        topic.update!(lease_token: token, lease_expires_at: TopicInvestigation::LEASE_FOR.from_now, error_code: nil)
      end
      job_class = if topic.queued?
        DiscoverTopicJob
      elsif topic.awaiting_analyses?
        MonitorTopicAnalysesJob
      elsif topic.full_analysis_required? && !topic.discovery["analysis_phase_complete"]
        StartTopicAnalysesJob
      else
        AssessTopicJob
      end
      args = job_class == MonitorTopicAnalysesJob ? [ id, run_token, token ] : [ id, run_token ]
      job = job_class.perform_later(*args)
      return true if job && job.successfully_enqueued?

      release(id, run_token, token)
      false
    rescue StandardError
      release(id, run_token, token) if token
      false
    end

    def self.release(id, run_token, token)
      changed = TopicInvestigation.where(id:, run_token:, lease_token: token, status: DELIVERABLE).update_all(
        lease_token: nil, lease_expires_at: nil, error_code: "enqueue_failed", updated_at: Time.current
      )
      RefreshTopicReportJob.notify(id, run_token) if changed == 1
    end
    private_class_method :release
  end
end
