module Investigations
  # Broadcast an invalidation, never an asynchronously rendered report snapshot.
  # The replacement frame fetches current state; disconnected old frames cannot
  # paint a response over a later retry, even if broadcasts arrive out of order.
  class RefreshTopicReportJob < ApplicationJob
    queue_as :realtime

    def self.notify(id, run_token)
      ActiveRecord.after_all_transactions_commit do
        begin
          perform_later(id, run_token)
        rescue StandardError => error
          Rails.logger.warn("Topic progress notification unavailable (#{error.class.name})")
        end
      end
    end

    def perform(id, run_token)
      topic = TopicInvestigation.find_by(id:, run_token:)
      return unless topic
      Turbo::StreamsChannel.broadcast_replace_to(topic, target: ActionView::RecordIdentifier.dom_id(topic, :live),
        partial: "topic_investigations/reload", locals: { topic: })
    end
  end
end
