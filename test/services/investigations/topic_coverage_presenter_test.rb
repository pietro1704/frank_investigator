require "test_helper"

class TopicCoveragePresenterTest < ActiveSupport::TestCase
  setup do
    plan = Investigations::TopicPlan.call(JSON.parse(file_fixture("topic_discovery/structured_plan.json").read))
    @topic = TopicInvestigation.create!(question: "Schools?", status: :completed, report: { "conclusion" => "Insufficient evidence" }, discovery: {
      "plan" => plan, "news_ids" => [ "S1", "S2" ], "documents" => [
        { "id" => "S1", "url" => "https://one.example/report", "editorial_position" => "left", "editorial_confidence" => "documented" },
        { "id" => "S2", "url" => "https://two.example/report", "editorial_position" => "center", "editorial_confidence" => "provisional" } ] })
  end

  def link(id, url, **attributes)
    @topic.topic_analysis_links.create!({ source_id: id, source_url: url, run_token: @topic.run_token }.merge(attributes))
  end

  test "partial quotas count only current identified documented full analyses" do
    link("S1", "https://one.example/report", status: :ready)
    link("S2", "https://two.example/report", status: :failed, error_code: "analysis_timeout")
    link("S3", "https://other.example/report", status: :ready)
    result = TopicCoveragePresenter.call(@topic)
    assert_equal 6, result["requested"]
    assert_equal 2, result["selected"]
    assert_equal 1, result["analyzed"]
    assert_equal 1, result["failed"]
    assert_equal 1, result.dig("editorial_quotas", "left", "missing")
    assert_equal 2, result.dig("editorial_quotas", "center", "missing")
    refute result["complete"]
  end

  test "foreign generations and mismatched source identities never fill coverage" do
    link("S1", "https://one.example/report", status: :ready, run_token: "old-run")
    link("S2", "https://wrong.example/report", status: :ready)
    result = TopicCoveragePresenter.call(@topic)
    assert_equal 0, result["analyzed"]
    assert_equal 2, result["pending"]
  end

  test "complete processing can have uncertain factual verdicts" do
    plan = @topic.discovery["plan"].deep_dup
    plan["requirements"]["editorial_counts"] = { "left" => 1, "center" => 0, "right" => 0 }
    @topic.update!(discovery: @topic.discovery.merge("plan" => plan, "news_ids" => [ "S1" ]), report: { "conclusion" => "Insufficient evidence" })
    link("S1", "https://one.example/report", status: :ready)
    assert TopicCoveragePresenter.call(@topic)["complete"]
  end

  test "internal sampling target is not presented as an explicit request" do
    plan = @topic.discovery["plan"].deep_dup
    plan["requirements"]["editorial_counts"] = { "left" => 0, "center" => 0, "right" => 0 }
    @topic.update!(discovery: @topic.discovery.merge("plan" => plan))
    assert_nil TopicCoveragePresenter.call(@topic)["requested"]
  end
end
