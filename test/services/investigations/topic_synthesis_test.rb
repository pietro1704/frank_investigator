require "test_helper"

class Investigations::TopicSynthesisTest < ActiveSupport::TestCase
  setup do
    @input = JSON.parse(File.read(Rails.root.join("test/fixtures/files/topic_assessment/synthesis_input.json")))
    @raw = JSON.parse(File.read(Rails.root.join("test/fixtures/files/topic_assessment/synthesis_response.json")))
    @discovery = JSON.parse(File.read(Rails.root.join("test/fixtures/files/topic_assessment/input.json")))
    @report = { "question" => @input.fetch("question"), "articles" => @input.fetch("article_assessments"), "model_result" => {} }
    @model = Object.new
    raw = @raw
    @model.define_singleton_method(:synthesize) { |input:| raw.deep_dup }
  end

  def synthesize(**options)
    Investigations::TopicSynthesis.call(discovery: @discovery, report: @report, model: @model, **options)
  end

  test "live-observed synthesis preserves original question and grounded section provenance" do
    result = synthesize
    assert_equal @input.fetch("question"), result.fetch("question")
    assert_equal [ "Q1" ], result.fetch("sections").pluck("question_id")
    assert_equal @input.fetch("question"), result.fetch("sections").sole.fetch("question")
    assert result.fetch("synthesis_sources").all? { |item| item["url"].present? && !item.key?("body") }
    assert result.fetch("conclusion").present?
  end

  test "mismatched populations territories periods or metrics veto definitive support" do
    section = @raw.fetch("sections").first
    section["verdict"] = "supported"
    section.fetch("evidence").each { |item| item["scope_match"]["territory"] = false }
    result = synthesize
    assert_equal "needs_more_evidence", result.fetch("sections").sole.fetch("verdict")
    assert_includes result.fetch("conclusion"), I18n.t("topic_synthesis.scope_mismatch")
  end

  test "fabricated quotations source identities or subquestion identities fail closed" do
    section = @raw.fetch("sections").first
    original = section.deep_dup
    section["question_id"] = "Q99"
    assert_raises(Investigations::TopicAssessment::InvalidResponse) { synthesize }
    section.replace(original.deep_dup)
    section.fetch("evidence").first["source_id"] = "foreign"
    assert_raises(Investigations::TopicAssessment::InvalidResponse) { synthesize }
    section.replace(original.deep_dup)
    section.fetch("evidence").first["quote"] = "This quotation was never read in any document."
    assert_raises(Investigations::TopicAssessment::InvalidResponse) { synthesize }
  end

  test "lack of original evidence cannot turn repeated news into factual support" do
    @raw.fetch("sections").first["verdict"] = "supported"
    @discovery.fetch("documents").each { |item| item["kind"] = "news_article" }
    assert_equal "needs_more_evidence", synthesize.fetch("sections").sole.fetch("verdict")
  end

  test "opposing original evidence vetoes definitive support even when marked applicable" do
    section = @raw.fetch("sections").first
    section["verdict"] = "supported"
    section.fetch("evidence").each { |item| item["scope_match"] = Investigations::TopicSynthesis::DIMENSIONS.index_with { true } }
    result = synthesize
    assert_equal "mixed", result.fetch("sections").sole.fetch("verdict")
    assert_includes result.fetch("conclusion"), I18n.t("topic_assessment.guards.conflict")
  end

  test "each requested dimension can independently limit support" do
    section = @raw.fetch("sections").first
    original = section.deep_dup
    Investigations::TopicSynthesis::DIMENSIONS.each do |dimension|
      section.replace(original.deep_dup)
      section["verdict"] = "supported"
      section.fetch("evidence").each do |item|
        item["scope_match"] = Investigations::TopicSynthesis::DIMENSIONS.index_with { true }
        item["scope_match"][dimension] = false
      end
      assert_equal "needs_more_evidence", synthesize.fetch("sections").sole.fetch("verdict"), dimension
    end
  end

  test "a late model response is discarded after cancellation" do
    cancelled = false
    raw = @raw
    @model.define_singleton_method(:synthesize) { |input:| cancelled = true; raw }
    assert_raises(Investigations::TopicDiscovery::Cancelled) { synthesize(cancelled: -> { cancelled }) }
  end

  test "subquestions retain identity and plan order even when model sections are reordered" do
    @discovery["plan"] = { "requirements" => { "subquestions" => [ "Brazilian schools", "Worldwide universities" ] } }
    first = @raw.fetch("sections").first.deep_dup
    second = first.deep_dup.merge("question_id" => "Q2")
    @raw["sections"] = [ second, first ]
    result = synthesize
    assert_equal %w[Q1 Q2], result.fetch("sections").pluck("question_id")
    assert_equal [ "Brazilian schools", "Worldwide universities" ], result.fetch("sections").pluck("question")
    @report["question"] = "A different research question"
    assert_raises(Investigations::TopicAssessment::InvalidResponse) { synthesize }
  end

  test "applicable original support can sustain the specifically scoped statement" do
    question = "O SAD registrou queda do desmatamento entre janeiro e dezembro de 2024?"
    @discovery["question"] = @report["question"] = @raw["question"] = question
    section = @raw.fetch("sections").first
    section["verdict"] = "supported"
    section["evidence"] = [ section["evidence"].first ]
    section["evidence"].first["scope_match"] = Investigations::TopicSynthesis::DIMENSIONS.index_with { true }
    assert_equal "supported", synthesize.fetch("sections").sole.fetch("verdict")
  end

  test "cancelled research never publishes a synthesis" do
    assert_raises(Investigations::TopicDiscovery::Cancelled) { synthesize(cancelled: -> { true }) }
  end
end
