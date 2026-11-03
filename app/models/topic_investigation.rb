class TopicInvestigation < ApplicationRecord
  class InvalidDiscovery < StandardError; end
  class InvalidReport < StandardError; end

  has_many :topic_analysis_links, dependent: :delete_all

  LEASE_FOR = 5.minutes
  ACTIVE_STATUSES = %w[queued researching awaiting_assessment assessing awaiting_analyses monitoring_analyses].freeze
  DISCOVERY_STAGES = %w[planning searching_news reading_news screening searching_evidence reading_evidence classifying profiling_editorial].freeze

  enum :status, {
    queued: "queued", researching: "researching", awaiting_assessment: "awaiting_assessment",
    assessing: "assessing", awaiting_analyses: "awaiting_analyses", monitoring_analyses: "monitoring_analyses", completed: "completed", no_news: "no_news", failed: "failed", cancelled: "cancelled"
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

  def execution_current?(run_token:, lease_token:, phase: "researching")
    execution_scope(run_token:, lease_token:, phase:).exists?
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

  def fail_execution!(run_token:, lease_token:, code:, phase: "researching")
    execution_scope(run_token:, lease_token:, phase:).update_all(status: "failed", stage: "failed", error_code: code,
      lease_token: nil, lease_expires_at: nil, finished_at: Time.current, updated_at: Time.current) == 1
  end

  def claim_assessment!(run_token:)
    token = SecureRandom.uuid
    changed = self.class.where(id:, run_token:, status: "awaiting_assessment").update_all(
      status: "assessing", stage: "assessing", lease_token: token, lease_expires_at: LEASE_FOR.from_now,
      error_code: nil, updated_at: Time.current)
    token if changed == 1
  end

  def finish_assessment!(run_token:, lease_token:, report:)
    valid = report.is_a?(Hash) && report["question"] == question && report["conclusion"].is_a?(String) && report["conclusion"].present?
    articles = report["articles"] if valid
    valid &&= articles.is_a?(Array) && articles.any? && articles.all? { |item| item.is_a?(Hash) && item["source_id"].is_a?(String) }
    valid &&= articles.pluck("source_id").sort == Array(discovery["news_ids"]).sort
    raise InvalidReport unless valid
    execution_scope(run_token:, lease_token:, phase: "assessing").update_all(status: "completed", stage: "completed", report:,
      lease_token: nil, lease_expires_at: nil, finished_at: Time.current, updated_at: Time.current) == 1
  end

  def checkpoint_assessment!(run_token:, lease_token:, stage:, checkpoint: nil)
    raise InvalidReport unless stage.in?(%w[assessing synthesizing])
    attributes = { stage:, lease_expires_at: LEASE_FOR.from_now, updated_at: Time.current }
    attributes[:assessment_checkpoint] = checkpoint if checkpoint
    execution_scope(run_token:, lease_token:, phase: "assessing").update_all(attributes) == 1
  end

  def resumable?
    return false unless status.in?(%w[failed cancelled]) && full_analysis_required? && discovery["status"] == "discovered"
    ids = Array(discovery["news_ids"])
    return false if ids.empty? || ids.uniq != ids
    documents = Array(discovery["documents"]).index_by { |item| item["id"] }
    links = topic_analysis_links.for_run(run_token).includes(:investigation).to_a
    links.pluck(:source_id).sort == ids.sort && links.all? do |link|
      link.investigation&.normalized_url == link.source_url && documents[link.source_id]&.fetch("url", nil) == link.source_url
    end
  end

  def synthesis_progress
    state = assessment_checkpoint
    sections = state.dig("synthesis", "sections")
    completed = state["run_token"] == run_token && sections.is_a?(Hash) ? sections.size : 0
    total = Array(discovery.dig("plan", "requirements", "subquestions")).size
    { "completed" => completed, "total" => [ total, 1 ].max }
  end

  def full_analysis_required?
    discovery.dig("plan", "version").to_i >= 2
  end

  def wait_for_analyses!(run_token:, lease_token:)
    snapshot = discovery.deep_dup
    snapshot["analysis_started_at"] = Time.current.iso8601
    execution_scope(run_token:, lease_token:, phase: "assessing").update_all(status: "awaiting_analyses", stage: "awaiting_analyses",
      discovery: snapshot, lease_token: nil, lease_expires_at: nil, updated_at: Time.current) == 1
  end

  def claim_monitoring!(run_token:, delivery_token: nil)
    with_lock do
      return unless self.run_token == run_token && awaiting_analyses?
      return if lease_expires_at&.future? && (delivery_token.blank? || lease_token != delivery_token)
      token = SecureRandom.uuid
      update!(status: :monitoring_analyses, stage: "monitoring_analyses", lease_token: token,
        lease_expires_at: LEASE_FOR.from_now, error_code: nil)
      token
    end
  end

  def publish_analysis_progress!(run_token:, lease_token:, snapshots:, pending:)
    snapshot = discovery.deep_dup
    snapshot["full_analyses"] = snapshots
    ready = snapshots.any? { |item| item["status"] == "ready" }
    state = pending ? "awaiting_analyses" : (ready ? "awaiting_assessment" : "failed")
    snapshot["analysis_phase_complete"] = true unless pending
    execution_scope(run_token:, lease_token:, phase: "monitoring_analyses").update_all(status: state, stage: state, discovery: snapshot,
      lease_token: nil, lease_expires_at: (Investigations::MonitorTopicAnalysesJob::POLL_DELAY.from_now if pending),
      error_code: ("analyses_failed" if state == "failed"), finished_at: (Time.current if state == "failed"), updated_at: Time.current) == 1
  end

  def cancel!
    self.class.where(id:, status: ACTIVE_STATUSES).update_all(status: "cancelled", stage: "cancelled", error_code: nil,
      lease_token: nil, lease_expires_at: nil, finished_at: Time.current, updated_at: Time.current) == 1
  end

  private

  def execution_scope(run_token:, lease_token:, phase: "researching")
    self.class.where(id:, run_token:, lease_token:, status: phase)
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
    errors.add(:assessment_checkpoint, :invalid) unless assessment_checkpoint.is_a?(Hash)
  end
end
