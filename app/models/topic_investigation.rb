class TopicInvestigation < ApplicationRecord
  class InvalidDiscovery < StandardError; end

  LEASE_FOR = 5.minutes
  ACTIVE_STATUSES = %w[queued researching awaiting_assessment].freeze
  DISCOVERY_STAGES = %w[planning searching_news reading_news screening searching_evidence reading_evidence classifying].freeze

  enum :status, {
    queued: "queued", researching: "researching", awaiting_assessment: "awaiting_assessment",
    completed: "completed", no_news: "no_news", failed: "failed", cancelled: "cancelled"
  }, default: :queued, validate: true

  attr_readonly :question, :slug
  before_validation :set_identity, on: :create
  validates :question, presence: true, length: { maximum: Investigations::TopicDiscovery::MAX_QUESTION_LENGTH }, format: { with: /\A(?=.*\p{L}).*\z/m }
  validates :slug, :run_token, presence: true
  validates :report, presence: true, if: :completed?
  validate :payloads_are_objects

  def to_param
    slug
  end

  def claim_execution!(run_token:)
    token = SecureRandom.uuid
    changed = self.class.where(id:, run_token:, status: "queued").update_all(
      status: "researching", stage: "planning", lease_token: token,
      lease_expires_at: LEASE_FOR.from_now, started_at: Time.current, finished_at: nil,
      error_code: nil, updated_at: Time.current
    )
    token if changed == 1
  end

  def execution_current?(run_token:, lease_token:)
    execution_scope(run_token:, lease_token:).exists?
  end

  def checkpoint!(run_token:, lease_token:, stage:, discovery:)
    validate_discovery!(discovery)
    raise InvalidDiscovery unless DISCOVERY_STAGES.include?(stage)
    execution_scope(run_token:, lease_token:).update_all(stage:, discovery:,
      lease_expires_at: LEASE_FOR.from_now, updated_at: Time.current) == 1
  end

  def finish_discovery!(run_token:, lease_token:, discovery:)
    validate_discovery!(discovery)
    raise InvalidDiscovery unless %w[discovered no_news].include?(discovery["status"])
    state = discovery.fetch("status") == "discovered" ? "awaiting_assessment" : "no_news"
    execution_scope(run_token:, lease_token:).update_all(status: state, stage: state, discovery:,
      lease_token: nil, lease_expires_at: nil, finished_at: (Time.current if state == "no_news"), updated_at: Time.current) == 1
  end

  def fail_execution!(run_token:, lease_token:, code:)
    execution_scope(run_token:, lease_token:).update_all(status: "failed", stage: "failed", error_code: code,
      lease_token: nil, lease_expires_at: nil, finished_at: Time.current, updated_at: Time.current) == 1
  end

  def cancel!
    self.class.where(id:, status: ACTIVE_STATUSES).update_all(status: "cancelled", stage: "cancelled", error_code: nil,
      lease_token: nil, lease_expires_at: nil, finished_at: Time.current, updated_at: Time.current) == 1
  end

  private

  def execution_scope(run_token:, lease_token:)
    self.class.where(id:, run_token:, lease_token:, status: "researching")
  end

  def validate_discovery!(value)
    raise InvalidDiscovery unless value.is_a?(Hash) && value["question"] == question
  end

  def set_identity
    self.question = question.strip if question.is_a?(String)
    self.slug ||= SecureRandom.hex(12)
    self.run_token ||= SecureRandom.uuid
  end

  def payloads_are_objects
    errors.add(:discovery, :invalid) unless discovery.is_a?(Hash)
    errors.add(:report, :invalid) unless report.is_a?(Hash)
  end
end
