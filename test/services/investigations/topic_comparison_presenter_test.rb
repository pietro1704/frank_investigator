require "test_helper"

class TopicComparisonPresenterTest < ActiveSupport::TestCase
  setup do
    @discovery = JSON.parse(file_fixture("topic_assessment/input.json").read)
    @report = JSON.parse(file_fixture("topic_assessment/report.json").read)
    @topic = TopicInvestigation.new(question: @discovery["question"], status: :completed, discovery: @discovery, report: @report)
  end

  test "comparison retains article identities, actual quotations and shared evidence without independent votes" do
    rows = TopicComparisonPresenter.call(@topic)
    assert_equal %w[S2 S4], rows.pluck("source_id")
    assert_equal %w[supported needs_more_evidence], rows.pluck("verdict")
    assert rows.all? { |row| row["shared_source_ids"] == [ "S1" ] }
    refute rows.any? { |row| row["factual_challenge"] }
    rows.each do |row|
      assert_equal @discovery["documents"].find { |source| source["id"] == row["source_id"] }["url"], row["url"]
      assert row["citations"].any?
      refute row.key?("independent")
    end
  end

  test "only a grounded original disputing the central claim is a factual challenge" do
    article = @report["articles"].first
    source = @discovery["documents"].find { |item| item["id"] == article["source_id"] }
    source["title"] = source["body"] = article["article_quote"] = "O desmatamento regional aumentou no ano civil de 2024."
    article["verdict"] = "disputed"
    article["evidence"].first["relationship"] = "disputes"
    @topic.assign_attributes(discovery: @discovery, report: @report)
    assert TopicComparisonPresenter.call(@topic).first["factual_challenge"]
    article["evidence"].first["quote"] = "An invented contradiction with no original source passage"
    @topic.report = @report
    refute TopicComparisonPresenter.call(@topic).first["factual_challenge"]
  end

  test "editorial gaps are distinct from factual disputes and never infer deliberate omissions" do
    @report["articles"].first["weaknesses"] << "O veículo omitiu deliberadamente os números."
    @topic.report = @report
    row = TopicComparisonPresenter.call(@topic).first
    assert row["editorial_observations"].any?
    refute row["factual_challenge"]
    refute row["editorial_observations"].any? { |text| text.include?("deliberadamente") }
    @report["articles"].first["evidence"] = []
    @topic.report = @report
    assert_empty TopicComparisonPresenter.call(@topic).first["editorial_observations"]
  end

  test "a report entry cannot compare an unselected or invented source" do
    @report["articles"] << @report["articles"].first.merge("source_id" => "foreign")
    @topic.report = @report
    assert_equal %w[S2 S4], TopicComparisonPresenter.call(@topic).pluck("source_id")
  end
end
