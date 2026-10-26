require "test_helper"

class Investigations::TopicAssessmentTest < ActiveSupport::TestCase
  FIXTURES = Rails.root.join("test/fixtures/files/topic_assessment")

  class Model
    attr_reader :calls
    attr_accessor :after_call, :error, :response
    def initialize(response)
      @response, @calls = response, 0
    end
    def assess(discovery:)
      @calls += 1
      raise error if error
      after_call&.call
      response.deep_dup
    end
  end

  setup do
    @input = fixture("input")
    @raw = fixture("response")
    @model = Model.new(@raw)
  end

  test "assesses each real captured news article using literal external source evidence" do
    result = assess
    assert_equal @input.fetch("question"), result.fetch("question")
    assert_equal @input.fetch("news_ids").sort, result.fetch("articles").pluck("source_id").sort
    assert_equal "supported", result.fetch("articles").find { |item| item["source_id"] == "S2" }.fetch("verdict")
    assert_equal @raw, result.fetch("model_result")
    assert result.fetch("assessed_at").present?
    assert result.fetch("articles").all? { |item| item["evidence_ids"].is_a?(Array) }
  end

  test "producer classification without claim-specific original support cannot ratify a story" do
    article = supported_article
    article.fetch("evidence").each { |item| item["primary_reason"] = "" }
    result = assess
    item = result.fetch("articles").find { |entry| entry["source_id"] == article["source_id"] }
    assert_equal "needs_more_evidence", item.fetch("verdict")
    assert_equal "insufficient", item.fetch("overall_quality")
    assert_includes item.fetch("conclusion"), I18n.t("topic_assessment.guards.insufficient")
    assert_equal I18n.t("topic_assessment.adjusted"), result.fetch("conclusion")
  end

  test "self-citation cannot establish a supported verdict" do
    article = supported_article
    article["evidence"] = [ { "source_id" => article.fetch("source_id"), "quote" => article.fetch("article_quote"),
      "relationship" => "supports", "primary_reason" => "This article is its own original source." } ]
    item = assess.fetch("articles").find { |entry| entry["source_id"] == article["source_id"] }
    assert_equal "needs_more_evidence", item.fetch("verdict")
  end

  test "primary contradictions veto support even when secondary repetition is present" do
    article = supported_article
    primary = article.fetch("evidence").find { |item| item["primary_reason"].present? && item["relationship"] == "supports" }
    assert primary
    article.fetch("evidence") << primary.merge("relationship" => "disputes")
    article["overall_quality"] = "weak"
    item = assess.fetch("articles").find { |entry| entry["source_id"] == article["source_id"] }
    assert_equal "mixed", item.fetch("verdict")
    assert_equal "weak", item.fetch("overall_quality"), "a conservative factual adjustment must not improve a weak editorial assessment"
  end

  test "a numerical statement contradicted by its original producer can be marked incorrect" do
    article = supported_article
    article["article_quote"] = "Comparado a 2022, o avanço foi ainda maior: uma queda de 65%, já que naquele ano a destruição atingiu 10.573 km²."
    article["verdict"] = "disputed"
    article["conclusion"] = "O total de 2022 difere do publicado pelo produtor original para janeiro a dezembro."
    article["evidence"] = [ { "source_id" => "S1", "relationship" => "disputes",
      "quote" => "Já em relação 2022, quando a Amazônia teve 10.362 km² derrubados de janeiro a dezembro, a área desmatada em 2024 foi 65% menor.",
      "primary_reason" => "O Imazon publicou os números do próprio SAD para janeiro a dezembro de 2022, o mesmo período citado pela notícia." } ]
    item = assess.fetch("articles").find { |entry| entry["source_id"] == article["source_id"] }
    assert_equal "disputed", item.fetch("verdict")
  end

  test "absence of primary evidence cannot produce a false verdict" do
    article = supported_article
    article["verdict"] = "disputed"
    article["evidence"] = []
    item = assess.fetch("articles").find { |entry| entry["source_id"] == article["source_id"] }
    assert_equal "needs_more_evidence", item.fetch("verdict")
    assert_equal "insufficient", item.fetch("overall_quality")
  end

  test "an evaluative political judgment remains not checkable despite model support" do
    article = supported_article
    opinion = "O ministro foi um excelente ministro."
    @input.fetch("documents").find { |item| item["id"] == article["source_id"] }["body"] += "\n\n#{opinion}"
    article["article_quote"] = opinion
    item = assess.fetch("articles").find { |entry| entry["source_id"] == article["source_id"] }
    assert_equal "not_checkable", item.fetch("verdict")
  end

  test "a factual body excerpt does not ratify an evaluative headline" do
    article = supported_article
    @input.fetch("documents").find { |item| item["id"] == article["source_id"] }["title"] = "O ministro foi um excelente ministro."
    item = assess.fetch("articles").find { |entry| entry["source_id"] == article["source_id"] }
    assert_equal "not_checkable", item.fetch("verdict")
  end

  test "unknown duplicate or missing news identities invalidate the report" do
    original = @raw.fetch("articles").deep_dup
    [ original.drop(1), original + [ original.first ], original.map { |item| item.merge("source_id" => "foreign") } ].each do |items|
      @raw["articles"] = items
      assert_raises(Investigations::TopicAssessment::InvalidResponse) { assess }
    end
  end

  test "foreign question unknown evidence and fabricated quotations are rejected" do
    original = @raw.deep_dup
    mutations = [
      -> { @raw["question"] = "Another question" },
      -> { @raw["articles"].first["article_quote"] = "This quotation never appeared in the article." },
      -> { @raw["articles"].first["evidence"].first["source_id"] = "foreign" },
      -> { @raw["articles"].first["evidence"].first["quote"] = "This quotation never appeared in the source." }
    ]
    mutations.each do |mutate|
      @raw.replace(original.deep_dup)
      mutate.call
      assert_raises(Investigations::TopicAssessment::InvalidResponse) { assess }
    end
  end

  test "unreadable and truncated sources remain limitations and never substitute snippets" do
    @input["failures"] = [ { "url" => "https://example.com/unreadable", "reason" => "fetch_failed" } ]
    @input.fetch("documents").first["truncated"] = true
    result = assess
    assert_includes result.fetch("limitations"), I18n.t("topic_assessment.unreadable")
    assert_includes result.fetch("limitations"), I18n.t("topic_assessment.truncated")
  end

  test "cancellation before and after inference discards output" do
    assert_raises(Investigations::TopicDiscovery::Cancelled) { assess(cancelled: -> { true }) }
    assert_equal 0, @model.calls
    cancelled = false
    @model.after_call = -> { cancelled = true }
    assert_raises(Investigations::TopicDiscovery::Cancelled) { assess(cancelled: -> { cancelled }) }
    assert_equal 1, @model.calls
  end

  test "provider errors propagate without another provider or a heuristic truth verdict" do
    @model.error = Llm::Chatgpt::Error.new("subscription_sharing_usage_limit_exceeded")
    assert_raises(Llm::Chatgpt::Error) { assess }
    assert_equal 1, @model.calls
  end

  private

  def fixture(name)
    JSON.parse(File.read(FIXTURES.join("#{name}.json")))
  end

  def supported_article
    @raw.fetch("articles").find { |item| item["verdict"] == "supported" }
  end

  def assess(**options)
    Investigations::TopicAssessment.call(discovery: @input, model: @model, **options)
  end
end
