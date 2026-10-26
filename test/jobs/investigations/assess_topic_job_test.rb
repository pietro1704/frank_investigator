require "test_helper"

class Investigations::AssessTopicJobTest < ActiveJob::TestCase
  setup do
    root = Rails.root.join("test/fixtures/files/topic_assessment")
    input = JSON.parse(File.read(root.join("input.json")))
    @report = JSON.parse(File.read(root.join("report.json")))
    @topic = TopicInvestigation.create!(question: input.fetch("question"), status: :awaiting_assessment,
      stage: "awaiting_assessment", discovery: input)
    @calls = 0
  end

  test "validated assessment completes the matching topic exactly once" do
    with_assessment(->(**) { @report }) do
      perform
      perform
    end
    assert_equal 1, @calls
    assert_predicate @topic.reload, :completed?
    assert_equal @report, @topic.report
    assert @topic.finished_at
    assert_nil @topic.lease_token
  end

  test "foreign generations missing rows and wrong phases do not invoke a model" do
    with_assessment(->(**) { @report }) do
      Investigations::AssessTopicJob.perform_now(@topic.id, "foreign")
      Investigations::AssessTopicJob.perform_now(-1, @topic.run_token)
      @topic.update!(status: :queued)
      perform
    end
    assert_equal 0, @calls
    assert_empty @topic.reload.report
  end

  test "late completion after cancellation or restart cannot publish the old result" do
    old_token = @topic.run_token
    callback = lambda do |**options|
      @topic.cancel!
      Investigations::SubmitTopic.restart(topic: @topic)
      assert options.fetch(:cancelled).call
      @report
    end
    with_assessment(callback) { Investigations::AssessTopicJob.perform_now(@topic.id, old_token) }
    assert_predicate @topic.reload, :queued?
    assert_not_equal old_token, @topic.run_token
    assert_empty @topic.report
  end

  test "wrong question and wrong source identities never publish a completed report" do
    callback = ->(**) { @report.merge("question" => "another question") }
    with_assessment(callback) { perform }
    assert_predicate @topic.reload, :failed?
    assert_equal "invalid_result", @topic.error_code
    assert_empty @topic.report
  end

  test "usage limits remain terminal and do not retry or switch providers" do
    callback = ->(**) { raise Llm::Chatgpt::Error.new("subscription_sharing_usage_limit_exceeded") }
    with_assessment(callback) { perform; perform }
    assert_equal 1, @calls
    assert_predicate @topic.reload, :failed?
    assert_equal "usage_limit", @topic.error_code
    assert_empty @topic.report
  end

  private

  def perform
    Investigations::AssessTopicJob.perform_now(@topic.id, @topic.run_token)
  end

  def with_assessment(callback)
    original = Investigations::TopicAssessment.method(:call)
    owner = self
    Investigations::TopicAssessment.define_singleton_method(:call) do |**options|
      owner.instance_variable_set(:@calls, owner.instance_variable_get(:@calls) + 1)
      callback.call(**options)
    end
    yield
  ensure
    Investigations::TopicAssessment.define_singleton_method(:call, original)
  end
end
