require "test_helper"

class Investigations::TopicSynthesisResumeTest < ActiveJob::TestCase
  setup do
    root = Rails.root.join("test/fixtures/files/topic_assessment")
    input = JSON.parse(File.read(root.join("input.json")))
    input["plan"] = { "version" => 2, "requirements" => { "subquestions" => [ "First question", "Second question" ] } }
    @topic = TopicInvestigation.create!(question: input["question"], status: :awaiting_assessment, discovery: input)
    Investigations::StartTopicAnalysesJob.perform_now(@topic.id, @topic.run_token)
    @topic.reload.topic_analysis_links.each do |link|
      link.investigation.root_article.update!(fetch_status: :fetched, fetched_at: Time.current)
      link.investigation.update!(status: :completed, analysis_completed_at: Time.current)
    end
    monitor
    @assessment_calls, @synthesis_calls, @timed_out = 0, [], false
    response = JSON.parse(File.read(root.join("response.json")))
    synthesis = JSON.parse(File.read(root.join("synthesis_response.json")))
    owner = self
    @assessment_class = Investigations::TopicAssessment::ResearchModel
    @previous_assess = @assessment_class.instance_method(:assess)
    @assessment_class.define_method(:assess) do |discovery:|
      owner.instance_variable_set(:@assessment_calls, owner.instance_variable_get(:@assessment_calls) + 1)
      response.deep_dup
    end
    @synthesis_class = Investigations::TopicSynthesis::ResearchModel
    @previous_synthesize = @synthesis_class.instance_method(:synthesize)
    @synthesis_class.define_method(:synthesize) do |input:|
      id = input["subquestions"].sole["question_id"]
      owner.instance_variable_get(:@synthesis_calls) << id
      if id == "Q2" && !owner.instance_variable_get(:@timed_out)
        owner.instance_variable_set(:@timed_out, true)
        raise Timeout::Error
      end
      synthesis.deep_dup.tap { |raw| raw["sections"].first["question_id"] = id }
    end
    clear_enqueued_jobs
  end

  teardown do
    @assessment_class.define_method(:assess, @previous_assess) if @previous_assess
    @synthesis_class.define_method(:synthesize, @previous_synthesize) if @previous_synthesize
  end

  def monitor
    Investigations::MonitorTopicAnalysesJob.perform_now(@topic.id, @topic.run_token, @topic.reload.lease_token)
    @topic.reload
  end

  def assess
    Investigations::AssessTopicJob.perform_now(@topic.id, @topic.run_token)
    @topic.reload
  end

  test "explicit retry preserves validated work and rechecks the same full analysis identities" do
    assess
    assert_predicate @topic, :failed?
    assert_equal "synthesis_timeout", @topic.error_code
    assert_predicate @topic, :resumable?
    assert_equal 1, @topic.synthesis_progress["completed"]
    assert_empty @topic.report
    previous = @topic.run_token
    original_discovery = @topic.discovery["documents"].deep_dup
    count = Investigation.count
    clear_enqueued_jobs
    Investigations::SubmitTopic.restart(topic: @topic)
    assert_predicate @topic.reload, :awaiting_analyses?
    assert_not_equal previous, @topic.run_token
    assert_equal original_discovery, @topic.discovery["documents"]
    assert_equal count, Investigation.count
    refute enqueued_jobs.any? { |job| job[:job] == Investigations::DiscoverTopicJob }
    monitor
    assess
    assert_predicate @topic, :completed?
    assert_equal 1, @assessment_calls
    assert_equal %w[Q1 Q2 Q2], @synthesis_calls
    assert_equal 2, @topic.synthesis_progress["completed"]
  end

  test "a changed source invalidates cached article and question assessments" do
    assess
    changed = @topic.discovery.deep_dup
    changed["documents"].first["body"] += " Additional source information."
    @topic.update!(discovery: changed)
    Investigations::SubmitTopic.restart(topic: @topic)
    monitor
    assess
    assert_predicate @topic, :completed?
    assert_equal 2, @assessment_calls
    assert_equal %w[Q1 Q2 Q1 Q2], @synthesis_calls
  end

  test "old generation callbacks cannot modify a resumed checkpoint" do
    assess
    old_run = @topic.run_token
    Investigations::SubmitTopic.restart(topic: @topic)
    before = @topic.reload.assessment_checkpoint.deep_dup
    refute @topic.checkpoint_assessment!(run_token: old_run, lease_token: "old", stage: "synthesizing", checkpoint: { "bad" => true })
    assert_equal before, @topic.reload.assessment_checkpoint
  end

  test "fresh retry explicitly clears source and synthesis checkpoints" do
    assess
    Investigations::SubmitTopic.restart(topic: @topic, fresh: true)
    assert_predicate @topic.reload, :queued?
    assert_empty @topic.assessment_checkpoint
    assert_empty @topic.discovery
    assert_enqueued_with(job: Investigations::DiscoverTopicJob)
  end
end
