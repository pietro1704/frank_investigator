require "test_helper"

class Investigations::TopicAnalysisMonitoringTest < ActiveJob::TestCase
  setup do
    input = JSON.parse(File.read(Rails.root.join("test/fixtures/files/topic_discovery/discovered.json")))
    input["plan"] = Investigations::TopicPlan.call(JSON.parse(File.read(Rails.root.join("test/fixtures/files/topic_discovery/plan.json")))).merge("version" => 2)
    @topic = TopicInvestigation.create!(question: input.fetch("question"), status: :awaiting_assessment, discovery: input, started_at: Time.current)
    clear_enqueued_jobs
  end

  def start
    Investigations::StartTopicAnalysesJob.perform_now(@topic.id, @topic.run_token)
    @topic.reload.topic_analysis_links.for_run(@topic.run_token).order(:id).to_a
  end

  def complete(link)
    link.investigation.root_article.update!(fetch_status: :fetched, fetched_at: Time.current)
    link.investigation.update!(status: :completed, analysis_completed_at: Time.current,
      llm_summary: { "overall_quality" => "mixed", "conclusion" => "A full analysis with explicit limitations" })
  end

  def monitor
    Investigations::MonitorTopicAnalysesJob.perform_now(@topic.id, @topic.run_token, @topic.reload.lease_token)
    @topic.reload
  end

  test "starts each full pipeline once and waits for pending members" do
    links = start
    assert_predicate @topic.reload, :awaiting_analyses?
    assert_equal @topic.discovery.fetch("news_ids").size, links.size
    assert links.all? { |link| link.investigation.auto_submit_limit == 0 }
    assert_no_difference "TopicAnalysisLink.count" do
      Investigations::StartTopicAnalysesJob.perform_now(@topic.id, @topic.run_token)
    end
    complete(links.first)
    monitor
    assert_predicate @topic, :awaiting_analyses?
    assert_predicate links.first.reload, :ready?
    assert_predicate links.last.reload, :pending?
    assert_empty @topic.report
  end

  test "ready members hand off to assessment with immutable snapshots and per-source provenance" do
    links = start
    links.each { |link| complete(link) }
    monitor
    assert_predicate @topic, :awaiting_assessment?
    assert_equal true, @topic.discovery["analysis_phase_complete"]
    snapshots = @topic.discovery.fetch("full_analyses")
    assert_equal @topic.discovery.fetch("news_ids").sort, snapshots.pluck("source_id").sort
    assert snapshots.all? { |item| item["status"] == "ready" && item["slug"].present? }
    assert_empty @topic.report
  end

  test "stale reports are not reused and total analysis failure never becomes a factual answer" do
    links = start
    links.each do |link|
      complete(link)
      link.investigation.update!(analysis_completed_at: 2.days.ago)
    end
    monitor
    assert_predicate @topic, :failed?
    assert_equal "analyses_failed", @topic.error_code
    assert links.all? { |link| link.reload.stale? }
    assert_empty @topic.report
  end

  test "pending group reconciliation is not a ready analysis and timeout is explicit" do
    links = start
    links.each { |link| complete(link) }
    member = links.first.investigation
    group = InvestigationGroup.create!(main_investigation: member, evidence_revision: 1)
    member.update!(investigation_group: group, group_membership_kind: :manual, evidence_revision_assessed: 0)
    monitor
    assert_predicate @topic, :awaiting_analyses?
    assert_predicate links.first.reload, :pending?
    travel 31.minutes do
      monitor
      assert_predicate @topic, :awaiting_assessment?
      assert_equal "analysis_timeout", links.first.reload.error_code
      assert_predicate member.reload, :completed?, "shared analysis must not be failed by topic timeout"
    end
  end

  test "ready snapshots retain evidence actually read by the full URL pipeline" do
    link = start.first
    complete(link)
    claim = Claim.create!(canonical_text: "A measurable survey result", canonical_fingerprint: SecureRandom.hex)
    assessment = ClaimAssessment.create!(investigation: link.investigation, claim:, verdict: :needs_more_evidence)
    article = Article.create!(url: "https://original.example.org/data", normalized_url: "https://original.example.org/data", host: "original.example.org",
      title: "Original survey", body_text: "The original producer describes the population and reference period of its survey.",
      fetch_status: :fetched, fetched_at: Time.current, authority_tier: :primary)
    EvidenceItem.create!(claim_assessment: assessment, article:, source_url: article.url)
    snapshot = Investigations::TopicAnalysisSnapshot.call(link.reload)
    source = snapshot.fetch("evidence_documents").sole
    assert_equal article.body_text, source["body"]
    assert_equal "producer_publication", source["kind"]
    assert_equal "A#{article.id}", source["id"]
  end

  test "snapshot refuses a report belonging to another source identity" do
    links = start
    foreign = Investigations::EnsureStarted.call(submitted_url: "https://different.example.org/article")
    links.first.update!(investigation: foreign)
    snapshot = Investigations::TopicAnalysisSnapshot.call(links.first.reload)
    assert_equal "failed", snapshot["status"]
    assert_equal "source_identity_mismatch", snapshot["error_code"]
  end

  test "cancelled and foreign generations cannot publish late full results" do
    links = start
    links.each { |link| complete(link) }
    @topic.cancel!
    Investigations::MonitorTopicAnalysesJob.perform_now(@topic.id, @topic.run_token)
    assert_predicate @topic.reload, :cancelled?
    assert_empty @topic.report
    assert_nil @topic.discovery["analysis_phase_complete"]
    Investigations::MonitorTopicAnalysesJob.perform_now(@topic.id, SecureRandom.uuid)
    assert_predicate @topic.reload, :cancelled?
  end
end
