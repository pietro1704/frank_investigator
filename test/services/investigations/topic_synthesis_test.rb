require "test_helper"

class Investigations::TopicSynthesisTest < ActiveSupport::TestCase
  setup do
    @input = JSON.parse(File.read(Rails.root.join("test/fixtures/files/topic_assessment/synthesis_input.json")))
    @raw = JSON.parse(File.read(Rails.root.join("test/fixtures/files/topic_assessment/synthesis_response.json")))
    @discovery = JSON.parse(File.read(Rails.root.join("test/fixtures/files/topic_assessment/input.json")))
    @report = { "question" => @input.fetch("question"), "articles" => @input.fetch("article_assessments"), "model_result" => {} }
    @model = Object.new
    raw = @raw
    @model.define_singleton_method(:synthesize) do |input:|
      payload = raw.deep_dup
      payload["sections"].select! { |section| input["subquestions"].pluck("question_id").include?(section["question_id"]) } if payload["sections"].size > 1
      payload
    end
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

  test "only citable documents are exposed and URL aliases retain their actual identifiers" do
    source = @discovery["documents"].first
    alias_source = source.merge("id" => "A711")
    @discovery["full_analyses"] = [ { "status" => "ready", "evidence_documents" => [ alias_source ] } ]
    raw = @raw
    @model.define_singleton_method(:synthesize) do |input:|
      raise "Ineligible index exposed to model" if input["documents"].any? { |item| item["kind"] == "index_or_other" }
      raise "Actual supplemental identity lost to URL deduplication" unless input["documents"].pluck("id").include?("A711")
      raw.deep_dup
    end
    result = synthesize
    assert_includes result["synthesis_sources"].pluck("id"), "A711"
    refute result["synthesis_sources"].any? { |item| item["kind"] == "index_or_other" }
  end

  test "a rejected citation is regenerated once and every returned citation is validated" do
    raw = @raw
    inputs = []
    @model.define_singleton_method(:synthesize) do |input:|
      inputs << input
      response = raw.deep_dup
      response["sections"].first["evidence"].first["source_id"] = "unread" if inputs.size == 1
      response
    end
    assert synthesize["sections"].any?
    assert_equal 2, inputs.size
    assert inputs.last["validation_feedback"].present?
    assert_equal inputs.first["documents"], inputs.last["documents"]
  end

  test "timeouts keep validated questions and resume only the missing question" do
    @discovery["plan"] = { "requirements" => { "subquestions" => [ "First question", "Second question" ] } }
    raw = @raw
    calls = []
    timeout = true
    @model.define_singleton_method(:synthesize) do |input:|
      id = input["subquestions"].sole["question_id"]
      calls << id
      raise Timeout::Error if id == "Q2" && timeout
      raw.deep_dup.tap { |payload| payload["sections"].first["question_id"] = id }
    end
    saved = nil
    assert_raises(Timeout::Error) { synthesize(on_progress: ->(checkpoint) { saved = checkpoint }) }
    assert_equal [ "Q1" ], saved["sections"].keys
    timeout = false
    result = synthesize(checkpoint: saved)
    assert_equal %w[Q1 Q2 Q2], calls
    assert_equal %w[Q1 Q2], result["sections"].pluck("question_id")
    @discovery["documents"].first["body"] += " Additional source context."
    synthesize(checkpoint: saved)
    assert_equal %w[Q1 Q2], calls.last(2), "Changed evidence must invalidate completed question caches"
  end

  test "conflicting supplemental identities fail instead of replacing an existing source" do
    original = @discovery["documents"].first
    @discovery["full_analyses"] = [ { "status" => "ready", "evidence_documents" => [ original.merge("body" => "A different article under the same ID") ] } ]
    assert_raises(Investigations::TopicAssessment::InvalidResponse) { synthesize }
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
