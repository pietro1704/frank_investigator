class TopicAnalysisLink < ApplicationRecord
  belongs_to :topic_investigation
  belongs_to :investigation, optional: true

  enum :status, { pending: "pending", ready: "ready", failed: "failed", stale: "stale" }, default: :pending, validate: true
  scope :for_run, ->(token) { where(run_token: token) }
  validates :run_token, :source_url, presence: true
  validates :source_id, format: { with: /\AS\d+\z/ }, uniqueness: { scope: [ :topic_investigation_id, :run_token ] }
  attr_readonly :topic_investigation_id, :run_token, :source_id, :source_url
end
