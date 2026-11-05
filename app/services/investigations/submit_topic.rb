module Investigations
  class SubmitTopic
    class Conflict < StandardError; end

    def self.call(question:)
      topic = TopicInvestigation.create!(question: TopicDiscovery.normalize_question(question), analysis_mode: :brief)
      schedule(topic.id, topic.run_token)
      topic
    end

    def self.restart(topic:, fresh: false)
      topic.with_lock do
        raise Conflict unless topic.status.in?(%w[failed cancelled no_news])
        if !fresh && topic.resumable?
          resume_in_transaction(topic)
        else
          topic.update!(status: :queued, stage: "queued", run_token: SecureRandom.uuid,
            discovery: {}, report: {}, assessment_checkpoint: {}, error_code: nil, started_at: nil, finished_at: nil,
            lease_token: nil, lease_expires_at: nil)
        end
      end
      schedule(topic.id, topic.run_token)
      topic
    end

    def self.resume_in_transaction(topic)
      previous = topic.run_token
      next_run = SecureRandom.uuid
      snapshot = topic.discovery.deep_dup
      snapshot.delete("analysis_phase_complete")
      snapshot["analysis_started_at"] = Time.current.iso8601
      checkpoint = topic.assessment_checkpoint["run_token"] == previous ? topic.assessment_checkpoint.deep_dup : {}
      checkpoint["run_token"] = next_run unless checkpoint.empty?
      topic.topic_analysis_links.for_run(previous).each do |link|
        topic.topic_analysis_links.create!(run_token: next_run, source_id: link.source_id, source_url: link.source_url, investigation_id: link.investigation_id)
      end
      phase = topic.full_analysis_required? ? "awaiting_analyses" : "awaiting_assessment"
      topic.update!(status: phase, stage: phase, run_token: next_run,
        discovery: snapshot, assessment_checkpoint: checkpoint, report: {}, error_code: nil, finished_at: nil,
        lease_token: nil, lease_expires_at: nil)
    end
    private_class_method :resume_in_transaction

    def self.schedule(id, run_token)
      ActiveRecord.after_all_transactions_commit { TopicResearchDelivery.dispatch(id, run_token) }
    end
    private_class_method :schedule
  end
end
