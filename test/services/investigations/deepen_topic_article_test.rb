require "test_helper"

class Investigations::DeepenTopicArticleTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @existing_investigations = Investigation.pluck(:id)
    @existing_topics = TopicInvestigation.pluck(:id)
    @discovery = JSON.parse(file_fixture("topic_assessment/input.json").read)
    report = JSON.parse(file_fixture("topic_assessment/report.json").read)
    @topic = TopicInvestigation.create!(question: @discovery["question"], status: :completed, discovery: @discovery, report:)
    @source = @discovery["documents"].find { |item| item["id"] == "S2" }
    @generation = Investigations::DeepenTopicArticle.generation(@topic)
    clear_enqueued_jobs
  end

  teardown do
    TopicInvestigation.where.not(id: @existing_topics).destroy_all
    Investigation.where.not(id: @existing_investigations).destroy_all
    clear_enqueued_jobs
  end

  test "starts the correct real URL pipeline exactly once with automatic expansion disabled" do
    first = nil
    assert_difference "Investigation.count", 1 do
      assert_difference "TopicAnalysisLink.count", 1 do
        first = deepen
      end
    end
    assert_equal @source["url"], first.investigation.normalized_url
    assert_equal 0, first.investigation.auto_submit_limit
    assert_enqueued_with(job: Investigations::KickoffJob, args: [ first.investigation.id, first.investigation.kickoff_delivery_token ])
    clear_enqueued_jobs
    assert_no_difference "Investigation.count" do
      assert_no_difference "TopicAnalysisLink.count" do
        assert_no_enqueued_jobs(only: Investigations::KickoffJob) { assert_equal first.investigation.id, deepen.investigation.id }
      end
    end
  end

  test "simultaneous submissions converge on one investigation and one source link" do
    ready, start, results = Queue.new, Queue.new, Queue.new
    topic_id, generation = @topic.id, @generation
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          topic = TopicInvestigation.find(topic_id)
          ready << true
          start.pop
          begin
            results << Investigations::DeepenTopicArticle.call(topic:, generation:, source_id: "S2")
          rescue Investigations::DeepenTopicArticle::Unavailable
            results << :retryable
          end
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each { |thread| assert thread.join(15), "submission did not finish" }
    outcomes = 2.times.map { results.pop }
    successful = outcomes.reject { |item| item == :retryable }
    assert successful.any?
    assert_equal 1, Investigation.where(normalized_url: @source["url"]).count
    assert_equal 1, @topic.topic_analysis_links.count
    assert_equal 1, successful.map { |item| item.investigation.id }.uniq.size
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end

  test "completed grouped and failed reports retain identity ownership and settings" do
    existing = Investigations::EnsureStarted.call(submitted_url: @source["url"])
    group = InvestigationGroup.create!(main_investigation: existing)
    existing.update!(status: :completed, investigation_group: group, group_membership_kind: :manual)
    clear_enqueued_jobs
    assert_no_difference "Investigation.count" do
      assert_no_enqueued_jobs(only: Investigations::KickoffJob) { assert_equal existing.id, deepen.investigation.id }
    end
    assert_nil existing.reload.auto_submit_limit
    assert_equal group.id, existing.investigation_group_id
    existing.update!(status: :failed)
    assert_equal existing.id, deepen.investigation.id
    assert_predicate existing.reload, :failed?
  end

  test "cancelled foreign and superseded generations cannot submit any work" do
    assert_no_difference "Investigation.count" do
      assert_raises(Investigations::DeepenTopicArticle::Conflict) { deepen(generation: "foreign") }
      assert_raises(Investigations::DeepenTopicArticle::Conflict) { deepen(source_id: "S1") }
      assert_raises(Investigations::DeepenTopicArticle::Conflict) { deepen(source_id: "unknown") }
      @topic.update!(status: :cancelled)
      assert_raises(Investigations::DeepenTopicArticle::Conflict) { deepen }
      @topic.update!(status: :completed, run_token: SecureRandom.uuid)
      assert_raises(Investigations::DeepenTopicArticle::Conflict) { deepen }
    end
    assert_no_enqueued_jobs(only: Investigations::KickoffJob)
  end

  test "linked foreign URL and a starter returning another article are rejected atomically" do
    other = Investigations::EnsureStarted.call(submitted_url: "https://example.com/another-article")
    @topic.topic_analysis_links.create!(run_token: @topic.run_token, source_id: "S2", source_url: @source["url"], investigation: other)
    assert_raises(Investigations::DeepenTopicArticle::Conflict) { deepen }
    @topic.topic_analysis_links.delete_all
    starter = Object.new
    starter.define_singleton_method(:call) { |**| other }
    assert_no_difference "TopicAnalysisLink.count" do
      assert_raises(Investigations::DeepenTopicArticle::Conflict) { deepen(starter:) }
    end
  end

  test "adapter failure keeps one durable intent and a retry redelivers rather than duplicating" do
    adapter = ActiveJob::Base.queue_adapter
    original_enqueue = adapter.method(:enqueue)
    adapter.define_singleton_method(:enqueue) do |job|
      raise "adapter offline" if job.is_a?(Investigations::KickoffJob)
      original_enqueue.call(job)
    end
    result = deepen
    assert result.delivery_deferred
    assert_equal 1, @topic.topic_analysis_links.count
    assert result.investigation.reload.kickoff_due_at
    assert_nil result.investigation.kickoff_delivery_token
    adapter.define_singleton_method(:enqueue, original_enqueue)
    assert_no_difference "Investigation.count" do
      assert_enqueued_with(job: Investigations::KickoffJob) { refute deepen.delivery_deferred }
    end
  ensure
    adapter.define_singleton_method(:enqueue, original_enqueue) if adapter && original_enqueue
  end

  test "a failure before commit rolls back every link and investigation" do
    starter = Object.new
    starter.define_singleton_method(:call) do |**options|
      Investigations::EnsureStarted.call(**options)
      raise "cannot persist submission"
    end
    assert_no_difference "Investigation.count" do
      assert_no_difference "TopicAnalysisLink.count" do
        assert_raises(Investigations::DeepenTopicArticle::Unavailable) { deepen(starter:) }
      end
    end
    assert_no_enqueued_jobs(only: Investigations::KickoffJob)
  end

  private

  def deepen(**options)
    Investigations::DeepenTopicArticle.call(topic: @topic, generation: @generation, source_id: "S2", **options)
  end
end
