require "test_helper"

class TopicAnswerPresenterTest < ActiveSupport::TestCase
  setup do
    @discovery = JSON.parse(file_fixture("topic_assessment/input.json").read)
    @report = JSON.parse(file_fixture("topic_assessment/report.json").read)
  end

  test "legacy articles give cited knowledge and explicit missing evidence" do
    answer = present
    assert_equal [ "S2" ], answer["known"].pluck("id")
    assert_equal [ "S4" ], answer["missing"].pluck("id")
    assert_empty answer["disputed"]
    answer.values.flatten.flat_map { |item| item["citations"] }.each do |cite|
      source = @discovery["documents"].find { |item| item["id"] == cite["source_id"] }
      assert_includes source["body"].squish, cite["quote"].squish
      assert_equal source["url"], cite["url"]
      refute cite.key?("decisive")
    end
  end

  test "unsupported invented and wrong-identity quotations cannot become known facts" do
    [ "invented citation never read here", @discovery["documents"][1]["body"].first(80) ].each do |quote|
      @report["articles"][0]["evidence"][0]["quote"] = quote
      answer = present
      assert_empty answer["known"]
      assert_equal "needs_more_evidence", answer["missing"][0]["verdict"]
      refute_equal @report["articles"][0]["conclusion"], answer["missing"][0]["conclusion"]
    end
  end

  test "opposing originals stay in dispute rather than in known facts" do
    @report["articles"][0]["verdict"] = "mixed"
    answer = present
    assert_empty answer["known"]
    assert_equal [ "S2" ], answer["disputed"].pluck("id")
  end

  test "synthesis respects applicable scope and retains the validated question identity" do
    raw = JSON.parse(file_fixture("topic_assessment/synthesis_response.json").read)
    @report["sections"] = raw["sections"].map { |item| item.merge("question" => @discovery["question"]) }
    answer = present
    assert_equal raw["sections"].size, answer.values.flatten.size
    @report["sections"].each do |section|
      section["verdict"] = "supported"
      section["evidence"].each { |item| item["scope_match"]["territory"] = false }
    end
    assert_empty present["known"]
  end

  private

  def present
    TopicAnswerPresenter.new(discovery: @discovery, report: @report).call
  end
end
