module Investigations
  class SubmitTopic
    class Conflict < StandardError; end

    def self.call(question:)
      topic = TopicInvestigation.create!(question: TopicDiscovery.normalize_question(question))
      schedule(topic.id, topic.run_token)
      topic
    end

    def self.restart(topic:)
      topic.with_lock do
        raise Conflict unless topic.status.in?(%w[failed cancelled no_news])
        topic.update!(status: :queued, stage: "queued", run_token: SecureRandom.uuid,
          discovery: {}, report: {}, error_code: nil, started_at: nil, finished_at: nil,
          lease_token: nil, lease_expires_at: nil)
      end
      schedule(topic.id, topic.run_token)
      topic
    end

    def self.schedule(id, run_token)
      ActiveRecord.after_all_transactions_commit { TopicResearchDelivery.dispatch(id, run_token) }
    end
    private_class_method :schedule
  end
end
