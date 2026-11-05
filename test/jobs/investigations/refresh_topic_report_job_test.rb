require "test_helper"

class Investigations::RefreshTopicReportJobTest < ActiveSupport::TestCase
  include ActionCable::TestHelper
  self.use_transactional_tests = false

  setup do
    @topic = TopicInvestigation.create!(question: "Which evidence is available?")
    clear_enqueued_jobs
  end

  teardown do
    @topic.destroy!
    clear_enqueued_jobs
  end

  test "state changes notify only after commit and rolled back work never broadcasts" do
    lease = nil
    TopicInvestigation.transaction do
      lease = @topic.claim_execution!(run_token: @topic.run_token)
      assert_no_enqueued_jobs(only: Investigations::RefreshTopicReportJob)
    end
    assert_enqueued_with(job: Investigations::RefreshTopicReportJob, args: [ @topic.id, @topic.run_token ], queue: "realtime")
    clear_enqueued_jobs
    TopicInvestigation.transaction do
      @topic.checkpoint!(run_token: @topic.run_token, lease_token: lease, stage: "reading_news", discovery: { "question" => @topic.question })
      raise ActiveRecord::Rollback
    end
    assert_no_enqueued_jobs
    assert_equal "planning", @topic.reload.stage
  end

  test "late progress and stale cancellation cannot affect or notify a newer generation" do
    old_run = @topic.run_token
    lease = @topic.claim_execution!(run_token: old_run)
    stale = TopicInvestigation.find(@topic.id)
    @topic.cancel!
    Investigations::SubmitTopic.restart(topic: @topic)
    clear_enqueued_jobs
    refute stale.cancel!
    refute stale.checkpoint!(run_token: old_run, lease_token: lease, stage: "reading_news", discovery: { "question" => @topic.question })
    assert_no_enqueued_jobs
    assert_predicate @topic.reload, :queued?
  end

  test "current broadcasts contain only a fresh-state frame and stale or foreign work emits nothing" do
    stream = Turbo::StreamsChannel.send(:stream_name_from, @topic)
    assert_no_broadcasts(stream) { Investigations::RefreshTopicReportJob.perform_now(@topic.id, "foreign") }
    assert_broadcasts(stream, 1) { Investigations::RefreshTopicReportJob.perform_now(@topic.id, @topic.run_token) }
    payload = JSON.parse(broadcasts(stream).last)
    assert_includes payload, "<turbo-frame"
    assert_includes payload, "/topic_investigations/#{@topic.slug}"
    refute_includes payload, @topic.question
    refute_includes payload, @topic.run_token
    old = @topic.run_token
    @topic.update!(run_token: SecureRandom.uuid)
    assert_no_broadcasts(stream) { Investigations::RefreshTopicReportJob.perform_now(@topic.id, old) }
  end

  test "notification adapter failures never roll back or fail research state" do
    original = Investigations::RefreshTopicReportJob.method(:perform_later)
    Investigations::RefreshTopicReportJob.define_singleton_method(:perform_later) { |*| raise "offline" }
    assert @topic.claim_execution!(run_token: @topic.run_token)
    assert_predicate @topic.reload, :researching?
  ensure
    Investigations::RefreshTopicReportJob.define_singleton_method(:perform_later, original) if original
  end

  test "failure cancellation and retry each schedule a current-state notification" do
    lease = @topic.claim_execution!(run_token: @topic.run_token)
    clear_enqueued_jobs
    assert_enqueued_with(job: Investigations::RefreshTopicReportJob) { @topic.fail_execution!(run_token: @topic.run_token, lease_token: lease, code: "interrupted") }
    assert_enqueued_with(job: Investigations::RefreshTopicReportJob) { Investigations::SubmitTopic.restart(topic: @topic) }
    clear_enqueued_jobs
    assert_enqueued_with(job: Investigations::RefreshTopicReportJob) { @topic.cancel! }
  end
end
