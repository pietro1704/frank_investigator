require "test_helper"

class Investigations::TopicBriefResearchTest < ActiveJob::TestCase
  setup do
    root = Rails.root.join("test/fixtures/files/topic_assessment")
    @input = JSON.parse(File.read(root.join("input.json")))
    @input["plan"] = { "version" => 2, "requirements" => { "subquestions" => [ "What does the evidence establish?" ] } }
    @response = JSON.parse(File.read(root.join("response.json")))
    @synthesis = JSON.parse(File.read(root.join("synthesis_response.json")))
    @topic = Investigations::SubmitTopic.call(question: @input.fetch("question"))
    @topic.reload.update!(status: :awaiting_assessment, stage: "awaiting_assessment", discovery: @input, lease_token: nil, lease_expires_at: nil)
    @assessment_calls = 0
    @synthesis_calls = 0
    owner = self
    @assessment_model = Investigations::TopicAssessment::ResearchModel
    @old_assess = @assessment_model.instance_method(:assess)
    @assessment_model.define_method(:assess) do |discovery:|
      owner.instance_variable_set(:@assessment_calls, owner.instance_variable_get(:@assessment_calls) + 1)
      owner.instance_variable_get(:@response).deep_dup
    end
    @synthesis_model = Investigations::TopicSynthesis::ResearchModel
    @old_synthesize = @synthesis_model.instance_method(:synthesize)
    @synthesis_model.define_method(:synthesize) do |input:|
      owner.instance_variable_set(:@synthesis_calls, owner.instance_variable_get(:@synthesis_calls) + 1)
      callback = owner.instance_variable_get(:@during_synthesis)
      callback.call if callback
      owner.instance_variable_get(:@synthesis).deep_dup
    end
    clear_enqueued_jobs
  end

  teardown do
    @assessment_model.define_method(:assess, @old_assess)
    @synthesis_model.define_method(:synthesize, @old_synthesize)
  end

  test "a submitted structured question goes directly to cited synthesis without full URL pipelines" do
    assert_enqueued_with(job: Investigations::AssessTopicJob) do
      assert Investigations::TopicResearchDelivery.dispatch(@topic.id, @topic.run_token)
    end
    refute enqueued_jobs.any? { |job| job[:job] == Investigations::StartTopicAnalysesJob }
    assert_no_difference [ "Investigation.count", "TopicAnalysisLink.count" ] do
      Investigations::AssessTopicJob.perform_now(@topic.id, @topic.run_token)
    end
    assert_predicate @topic.reload, :completed?
    assert_equal 1, @assessment_calls
    assert_equal 1, @synthesis_calls
    assert_equal [ "Q1" ], @topic.report.fetch("sections").pluck("question_id")
    assert_equal "needs_more_evidence", @topic.report.fetch("sections").sole.fetch("verdict")
    assert_equal "supported", @topic.report.fetch("articles").first.fetch("verdict")
    assert @topic.report.fetch("sections").sole.fetch("evidence").any?
    @topic.report.fetch("articles").each do |article|
      assert Investigations::TopicAssessment::QUALITIES.include?(article["overall_quality"])
      assert article["strengths"].any?
      assert article["weaknesses"].any?
    end
    assert TopicCoveragePresenter.call(@topic).fetch("complete"), "an internal sampling cap must not require six full analyses"
    assert_equal @input["news_ids"].size, TopicCoveragePresenter.call(@topic).fetch("analyzed")
  end

  test "brief research with a legacy plan still answers the original question" do
    @topic.update!(discovery: @input.except("plan"))
    Investigations::AssessTopicJob.perform_now(@topic.id, @topic.run_token)
    assert_predicate @topic.reload, :completed?
    assert_equal @topic.question, @topic.report["sections"].sole["question"]
    assert_equal 1, @synthesis_calls
    assert_empty @topic.topic_analysis_links
  end

  test "synthesis failure can resume the same evidence without searching or starting URL analyses" do
    @during_synthesis = -> { raise Timeout::Error }
    Investigations::AssessTopicJob.perform_now(@topic.id, @topic.run_token)
    assert_predicate @topic.reload, :failed?
    assert_equal "synthesis_timeout", @topic.error_code
    assert_predicate @topic, :resumable?
    assert_empty @topic.report
    old_token = @topic.run_token
    @during_synthesis = nil
    assert_no_difference [ "Investigation.count", "TopicAnalysisLink.count" ] do
      Investigations::SubmitTopic.restart(topic: @topic)
      assert_predicate @topic.reload, :awaiting_assessment?
      refute_equal old_token, @topic.run_token
      Investigations::AssessTopicJob.perform_now(@topic.id, @topic.run_token)
    end
    assert_predicate @topic.reload, :completed?
    assert_equal 1, @assessment_calls
    assert_equal 2, @synthesis_calls
  end

  test "cancellation and a fresh generation reject late synthesis" do
    old_run = @topic.run_token
    @during_synthesis = lambda do
      @topic.cancel!
      Investigations::SubmitTopic.restart(topic: @topic, fresh: true)
    end
    Investigations::AssessTopicJob.perform_now(@topic.id, old_run)
    assert_predicate @topic.reload, :queued?
    refute_equal old_run, @topic.run_token
    assert_empty @topic.report
    assert_empty @topic.assessment_checkpoint
  end

  test "an optional failed deepening does not downgrade the question answer or its coverage" do
    Investigations::AssessTopicJob.perform_now(@topic.id, @topic.run_token)
    @topic.reload
    source = @input["documents"].find { |item| item["id"] == @input["news_ids"].first }
    @topic.topic_analysis_links.create!(run_token: @topic.run_token, source_id: source["id"],
      source_url: source["url"], status: :failed, error_code: "analysis_timeout")
    coverage = TopicCoveragePresenter.call(@topic)
    assert coverage["complete"]
    assert_equal 0, coverage["failed"]
    assert_nil coverage["sources"].first["error_code"]
    assert_equal "supported", @topic.report["articles"].first["verdict"]
  end

  test "foreign generation and delayed full-analysis jobs cannot start article pipelines" do
    assert_no_difference [ "Investigation.count", "TopicAnalysisLink.count" ] do
      Investigations::AssessTopicJob.perform_now(@topic.id, "old-run")
      Investigations::StartTopicAnalysesJob.perform_now(@topic.id, @topic.run_token)
    end
    assert_equal 0, @assessment_calls
    assert_empty @topic.reload.report
    assert_raises(ActiveRecord::ReadonlyAttributeError) { @topic.analysis_mode = :full }
  end

  test "foreign evidence identities cannot publish a topic answer" do
    @synthesis["sections"].first["evidence"].first["source_id"] = "FOREIGN"
    Investigations::AssessTopicJob.perform_now(@topic.id, @topic.run_token)
    assert_predicate @topic.reload, :failed?
    assert_equal "synthesis_invalid", @topic.error_code
    assert_empty @topic.report
  end

  test "foreign question identity cannot publish a topic answer" do
    @synthesis["question"] = "Different question"
    Investigations::AssessTopicJob.perform_now(@topic.id, @topic.run_token)
    assert_predicate @topic.reload, :failed?
    assert_equal "synthesis_invalid", @topic.error_code
    assert_empty @topic.report
  end
end
