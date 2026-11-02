module Investigations
  class MonitorTopicAnalysesJob < ApplicationJob
    queue_as :default
    POLL_DELAY = 10.seconds

    def perform(topic_id, run_token, delivery_token = nil)
      topic = TopicInvestigation.find_by(id: topic_id)
      return unless topic
      lease = topic.claim_monitoring!(run_token:, delivery_token:)
      return unless lease
      pending = false
      changed = topic.with_lock do
        next false unless topic.execution_current?(run_token:, lease_token: lease, phase: "monitoring_analyses")
        links = topic.topic_analysis_links.for_run(run_token).order(:id).to_a
        raise TopicInvestigation::InvalidDiscovery unless links.pluck(:source_id).sort == Array(topic.discovery["news_ids"]).sort
        started_at = Time.iso8601(topic.discovery.fetch("analysis_started_at"))
        timed_out = started_at <= ENV.fetch("FRANK_TOPIC_ANALYSIS_TIMEOUT_SECONDS", 1800).to_i.clamp(30, 3600).seconds.ago
        snapshots = links.map do |link|
          snapshot = TopicAnalysisSnapshot.call(link)
          snapshot.merge!("status" => "failed", "error_code" => "analysis_timeout") if snapshot["status"] == "pending" && timed_out
          link.update!(status: snapshot.fetch("status"), error_code: snapshot["error_code"], report_snapshot: snapshot, checked_at: Time.current)
          snapshot
        end
        pending = snapshots.any? { |item| item["status"] == "pending" }
        topic.publish_analysis_progress!(run_token:, lease_token: lease, snapshots:, pending:)
      end
      return unless changed
      if pending
        # The waiting row is durable intent if this scheduled delivery is lost.
        self.class.set(wait: POLL_DELAY).perform_later(topic_id, run_token)
      else
        ActiveRecord.after_all_transactions_commit { TopicResearchDelivery.dispatch(topic_id, run_token) }
      end
    rescue StandardError => error
      topic.fail_execution!(run_token:, lease_token: lease, phase: "monitoring_analyses", code: "analysis_monitoring_failed") if topic && lease
      Rails.logger.warn("Topic analysis monitoring failed (#{error.class.name})")
    end
  end
end
