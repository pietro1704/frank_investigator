require "test_helper"

class Investigations::TopicSourceSelectionTest < ActiveSupport::TestCase
  def source(id, side, body: nil, confidence: "documented")
    { "id" => id, "url" => "https://#{id.downcase}.example.org/report", "body" => body || ("#{id}uniqueword " * 60),
      "kind" => "news_article", "editorial_position" => side, "editorial_confidence" => confidence }
  end

  def select_sources(docs, counts = { "left" => 1, "center" => 1, "right" => 1 })
    Investigations::TopicSourceSelection.call(documents: docs, relevant_ids: docs.pluck("id"), editorial_counts: counts)
  end

  test "explicit overall count bounds selection without editorial quotas" do
    docs = (1..5).map { |i| source("S#{i}", "unknown", confidence: "unknown") }
    result = Investigations::TopicSourceSelection.call(documents: docs, relevant_ids: docs.pluck("id"),
      editorial_counts: { "left" => 0, "center" => 0, "right" => 0 }, news_count: 3)
    assert_equal 3, result["news_ids"].size
    assert result["coverage_complete"]
  end

  test "a documented candidate is retained ahead of uncertain coverage from the same owner" do
    unknown = source("S1", "unknown", confidence: "unknown")
    known = source("S2", "left").merge("url" => unknown["url"] + "-followup")
    result = select_sources([ unknown, known ], { "left" => 1, "center" => 0, "right" => 0 })
    assert_equal [ "S2" ], result["news_ids"]
    assert result["coverage_complete"]
    assert_equal [ "S1" ], result["excluded"].pluck("id")
  end

  test "quotas use documented positions only and do not substitute primary evidence" do
    docs = [ source("S1", "left"), source("S2", "center", confidence: "provisional"), source("S3", "right"), source("S4", "center") ]
    docs << source("S5", "center").merge("kind" => "producer_publication")
    result = select_sources(docs)
    assert_equal %w[S1 S4 S3], result.fetch("news_ids")
    assert result.fetch("coverage_complete")
    assert_equal 0, result.fetch("missing").values.sum
    result = select_sources(docs.reject { |item| item["id"] == "S4" })
    refute result.fetch("coverage_complete")
    assert_equal 1, result.dig("missing", "center")
    assert_includes result.fetch("uncertain_ids"), "S2"
  end

  test "republications cannot manufacture independent voices across positions" do
    body = "One original report about a documented educational survey. " * 60
    docs = [ source("S1", "left", body:), source("S2", "right", body:) ]
    result = select_sources(docs, { "left" => 1, "center" => 0, "right" => 1 })
    assert_equal [ "S1" ], result.fetch("news_ids")
    refute result.fetch("coverage_complete")
    assert_equal "same_origin", result.fetch("excluded").sole.fetch("reason")
  end

  test "missing requested perspectives remain gaps with useful uncertain context" do
    result = select_sources([ source("S1", "unknown", confidence: "unknown") ])
    assert_equal [ "S1" ], result.fetch("news_ids")
    assert_equal 3, result.fetch("missing").values.sum
    refute result.fetch("coverage_complete")
  end
end
