require "test_helper"

class TopicPartialAnswerPresenterTest < ActiveSupport::TestCase
  setup do
    discovery = JSON.parse(file_fixture("topic_assessment/input.json").read)
    report = JSON.parse(file_fixture("topic_assessment/report.json").read)
    @topic = TopicInvestigation.new(question: discovery["question"], status: :assessing, stage: "synthesizing", discovery:, run_token: SecureRandom.uuid)
    @topic.assessment_checkpoint = { "version" => 1, "run_token" => @topic.run_token,
      "discovery_fingerprint" => Investigations::TopicResearchFingerprint.discovery(discovery), "report" => report }
  end

  test "partial findings replay normal guards without an external model call" do
    result = TopicPartialAnswerPresenter.call(@topic)
    assert_equal [ "S2" ], result.dig("answer", "known").pluck("id")
    assert_equal [ "S4" ], result.dig("answer", "missing").pluck("id")
    refute_includes JSON.generate(result), "model_result"
    refute_includes JSON.generate(result), @topic.run_token
  end

  test "foreign generations changed evidence and resumed monitoring expose no partial facts" do
    state = @topic.assessment_checkpoint.deep_dup
    @topic.assessment_checkpoint = state.merge("run_token" => "old")
    assert_empty TopicPartialAnswerPresenter.call(@topic)
    @topic.assessment_checkpoint = state
    @topic.stage = "awaiting_analyses"
    assert_empty TopicPartialAnswerPresenter.call(@topic)
    @topic.stage = "synthesizing"
    @topic.discovery["documents"].first["body"] += " New evidence changed."
    assert_empty TopicPartialAnswerPresenter.call(@topic)
  end

  test "invented source quotes reject the whole unvalidated partial response" do
    @topic.assessment_checkpoint["report"]["model_result"]["articles"].first["evidence"].first["quote"] = "A quotation never read in this source body"
    assert_empty TopicPartialAnswerPresenter.call(@topic)
  end
end
