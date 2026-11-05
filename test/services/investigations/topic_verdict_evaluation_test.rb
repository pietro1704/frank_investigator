require "test_helper"

class Evaluations::TopicVerdictEvaluationTest < ActiveSupport::TestCase
  setup do
    @dataset = Evaluations::TopicVerdictDataset.load
  end

  test "all pinned cases and validation probes pass without external requests" do
    rows = []
    result = Evaluations::TopicVerdictRunner.new(dataset: @dataset).call { |row| rows << row }
    assert result["success"], result.inspect
    assert_equal 8, result.dig("counts", "passed")
    assert_equal %w[supported contradicted opinion inconclusive outdated circular invented_quote foreign_source], rows.pluck("id")
    assert_not_requested :any, %r{https?://}
  end

  test "immutable source hashes reject changed assets before running any candidate" do
    manifest = @dataset.manifest.deep_dup
    manifest["assets"]["captured"]["sha256"] = "0" * 64
    error = assert_raises(Evaluations::TopicVerdictDataset::Invalid) { Evaluations::TopicVerdictDataset.new(manifest) }
    assert_equal "source_digest_mismatch_captured", error.message
    manifest = @dataset.manifest.deep_dup
    manifest["assets"]["synthetic"]["path"] = ".env"
    assert_raises(Evaluations::TopicVerdictDataset::Invalid) { Evaluations::TopicVerdictDataset.new(manifest) }
  end

  test "scoring independently rejects unsupported confident verdicts and mismatched source citations" do
    entry = @dataset.cases.find { |item| item["id"] == "inconclusive" }
    report = entry.fetch("candidate_response").deep_dup
    report["articles"].first["conclusion"] = "É verdadeiro com certeza absoluta."
    score = Evaluations::TopicVerdictScore.call(entry:, report:)
    assert_includes score["failures"], "verdict"
    assert_includes score["failures"], "citation_support"
    assert_includes score["failures"], "overconfidence"
    entry = @dataset.cases.first
    report = entry.fetch("candidate_response").deep_dup
    report["articles"].first["evidence"].first["quote"] = "A passage never found in the fixed source"
    assert_includes Evaluations::TopicVerdictScore.call(entry:, report:)["failures"], "citation_support"
  end

  test "editorial quality is not factual confidence and foreign questions never borrow a case score" do
    entry = @dataset.cases.first
    report = entry.fetch("candidate_response").deep_dup
    report["articles"].first["overall_quality"] = "weak"
    assert_empty Evaluations::TopicVerdictScore.call(entry:, report:)["failures"]
    report["question"] = "A different question with the same source IDs"
    assert_includes Evaluations::TopicVerdictScore.call(entry:, report:)["failures"], "case_identity"
  end

  test "dated original evidence cannot refute or establish a disjoint current reference year" do
    entry = @dataset.cases.find { |item| item["id"] == "outdated" }
    %w[supported disputed].each do |verdict|
      raw = entry["candidate_response"].deep_dup
      article = raw["articles"].first
      article["verdict"] = verdict
      article["evidence"].first["relationship"] = verdict == "supported" ? "supports" : "disputes"
      report = Investigations::TopicAssessment.call(discovery: entry["discovery"], model: Evaluations::TopicVerdictRunner::RecordedModel.new(raw))
      assert_equal "needs_more_evidence", report["articles"].first["verdict"]
      assert_equal "context", report["articles"].first["evidence"].first["relationship"]
      assert_empty Evaluations::TopicVerdictScore.call(entry:, report:)["failures"]
    end
  end

  test "legacy dated article projections keep the old source as context rather than a current fact" do
    entry = @dataset.cases.find { |item| item["id"] == "outdated" }
    answer = TopicAnswerPresenter.new(discovery: entry["discovery"], report: entry["candidate_response"]).call
    assert_empty answer["known"]
    assert_empty answer["disputed"]
    assert_equal "needs_more_evidence", answer["missing"].first["verdict"]
    assert_equal "context", answer["missing"].first["citations"].first["relationship"]
  end

  test "live evaluation gets only discovery evidence and keeps curated answers out of the model input" do
    inputs = []
    factory = lambda do |entry, mode|
      assert_equal "live", mode
      response = entry.fetch("candidate_response")
      model = Object.new
      model.define_singleton_method(:assess) do |discovery:|
        inputs << discovery
        response
      end
      model
    end
    result = Evaluations::TopicVerdictRunner.new(dataset: @dataset, mode: "live", only: "supported", model_factory: factory).call
    assert result["success"]
    assert_equal 1, inputs.size
    %w[expected candidate_response candidate_origin rubric].each { |key| refute inputs.first.key?(key) }
    assert_equal @dataset.cases.first["question"], inputs.first["question"]
  end

  test "provider and malformed output failures are per case and never silently replaced" do
    calls = 0
    factory = lambda do |entry, _|
      calls += 1
      if entry["id"] == "supported"
        raise Llm::Chatgpt::Error.new("subscription_sharing_usage_limit_exceeded")
      end
      Evaluations::TopicVerdictRunner::RecordedModel.new(entry.fetch("candidate_response").merge("question" => "A foreign case"))
    end
    result = Evaluations::TopicVerdictRunner.new(dataset: @dataset, mode: "live", only: "supported,contradicted", model_factory: factory).call
    refute result["success"]
    assert_equal 2, calls
    assert_equal 2, result.dig("counts", "failed")
    assert_equal "Llm::Chatgpt::Error", result["results"].first["error_class"]
    assert_equal [ "invalid_model_response" ], result["results"].last["failures"]
    assert_equal "subscription_sharing_usage_limit_exceeded", result["results"].first["error_code"]
  end

  test "cancellation marks unfinished cases and never calls another model" do
    cancelled = false
    calls = 0
    factory = lambda do |entry, _|
      calls += 1
      model = Object.new
      model.define_singleton_method(:assess) do |discovery:|
        cancelled = true
        entry.fetch("candidate_response")
      end
      model
    end
    result = Evaluations::TopicVerdictRunner.new(dataset: @dataset, mode: "live", only: "supported,contradicted", model_factory: factory, cancelled: -> { cancelled }).call
    refute result["success"]
    assert_equal 1, calls
    assert_equal 2, result.dig("counts", "cancelled")
  end

  test "unknown cases and modes fail closed and validation probes are explicitly skipped in live mode" do
    assert_raises(Evaluations::TopicVerdictDataset::Invalid) { Evaluations::TopicVerdictRunner.new(mode: "typo") }
    assert_raises(Evaluations::TopicVerdictDataset::Invalid) { Evaluations::TopicVerdictRunner.new(only: "unknown") }
    result = Evaluations::TopicVerdictRunner.new(mode: "live", only: "invented_quote,foreign_source").call
    refute result["success"], "an entirely skipped run is not a successful evaluation"
    assert_equal 2, result.dig("counts", "skipped")
    assert_not_requested :any, %r{https?://}
  end
end
