class TopicPartialAnswerPresenter
  class RecordedModel
    def initialize(response)
      @response = response
    end

    def assess(discovery:)
      @response.deep_dup
    end
  end

  def self.call(topic)
    state = topic.assessment_checkpoint
    return {} unless topic.assessing? && topic.stage == "synthesizing" && state["version"] == 1 &&
      state["run_token"] == topic.run_token && topic.discovery["question"] == topic.question && state["discovery_fingerprint"] == Investigations::TopicResearchFingerprint.discovery(topic.discovery)
    saved = state["report"]
    return {} unless saved.is_a?(Hash) && saved["question"] == topic.question && saved["model_result"].is_a?(Hash)
    # Replay the normal validator/guards without a model request. A saved model
    # response alone is not a public partial result, even with a matching token.
    report = Investigations::TopicAssessment.call(discovery: topic.discovery, model: RecordedModel.new(saved["model_result"]))
    { "answer" => TopicAnswerPresenter.new(discovery: topic.discovery, report:).call,
      "scope" => report["scope"], "limitations" => report["limitations"] }
  rescue Investigations::TopicAssessment::InvalidResponse, KeyError, TypeError
    {}
  end
end
