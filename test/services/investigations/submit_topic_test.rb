require "test_helper"

class Investigations::SubmitTopicTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    TopicInvestigation.delete_all
    clear_enqueued_jobs
  end

  teardown do
    TopicInvestigation.delete_all
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "committed submissions enqueue a durable generation with the fetch worker" do
    topic = nil
    assert_enqueued_with(job: Investigations::DiscoverTopicJob, queue: "fetch") do
      topic = Investigations::SubmitTopic.call(question: "  Vacinas infantis  ")
    end
    assert_equal "Vacinas infantis", topic.question
    assert_predicate topic.reload, :queued?
    assert topic.slug.present?
    assert topic.run_token.present?
    assert topic.lease_token.present?
    assert_equal [ topic.id, topic.run_token ], enqueued_jobs.sole.fetch(:args)
    assert_equal topic.slug, topic.to_param
  end

  test "invalid original input cannot be coerced into a persisted question" do
    [ nil, [], {}, " ", "12345", "a" * 501 ].each do |question|
      assert_raises(Investigations::TopicDiscovery::InvalidQuestion) { Investigations::SubmitTopic.call(question:) }
    end
    assert_equal 0, TopicInvestigation.count
    assert_empty enqueued_jobs
  end

  test "outer transactions defer delivery and rollback removes both the record and intent" do
    assert_no_enqueued_jobs do
      TopicInvestigation.transaction do
        Investigations::SubmitTopic.call(question: "Vacinas infantis")
        assert_equal 1, TopicInvestigation.count
        assert_empty enqueued_jobs
        raise ActiveRecord::Rollback
      end
    end
    assert_equal 0, TopicInvestigation.count
  end

  test "delivery is fenced while queued and recovers a lost adapter delivery after its lease" do
    topic = Investigations::SubmitTopic.call(question: "Vacinas infantis")
    assert_equal 1, enqueued_jobs.size
    assert_not Investigations::TopicResearchDelivery.dispatch(topic.id, topic.run_token)
    assert_equal 1, enqueued_jobs.size
    travel 6.minutes do
      assert_enqueued_with(job: Investigations::DiscoverTopicJob, args: [ topic.id, topic.run_token ]) do
        Investigations::RecoverTopicResearchJob.perform_now
      end
    end
  end

  test "an enqueue exception leaves recoverable durable intent without leaking diagnostics" do
    original = Investigations::DiscoverTopicJob.method(:perform_later)
    Investigations::DiscoverTopicJob.define_singleton_method(:perform_later) { |*| raise "private adapter diagnostic" }
    topic = Investigations::SubmitTopic.call(question: "Vacinas infantis")
    assert_predicate topic.reload, :queued?
    assert_equal "enqueue_failed", topic.error_code
    assert_nil topic.lease_token
    assert_nil topic.lease_expires_at
    assert_empty enqueued_jobs
    Investigations::DiscoverTopicJob.define_singleton_method(:perform_later, original)
    assert_enqueued_with(job: Investigations::DiscoverTopicJob, args: [ topic.id, topic.run_token ]) do
      Investigations::RecoverTopicResearchJob.perform_now
    end
  ensure
    Investigations::DiscoverTopicJob.define_singleton_method(:perform_later, original) if original
  end

  test "an adapter rejecting enqueue is also recovered" do
    original = Investigations::DiscoverTopicJob.method(:perform_later)
    Investigations::DiscoverTopicJob.define_singleton_method(:perform_later) { |*| false }
    topic = Investigations::SubmitTopic.call(question: "Vacinas infantis")
    assert_equal "enqueue_failed", topic.reload.error_code
    assert_nil topic.lease_token
    assert_empty enqueued_jobs
  ensure
    Investigations::DiscoverTopicJob.define_singleton_method(:perform_later, original) if original
  end

  test "retrying a terminal failure creates a new generation and clears old report state" do
    topic = Investigations::SubmitTopic.call(question: "Vacinas infantis")
    topic.update!(status: :failed, discovery: { "old" => true }, report: { "old" => true }, error_code: "interrupted")
    old_token = topic.run_token
    assert_enqueued_with(job: Investigations::DiscoverTopicJob) { Investigations::SubmitTopic.restart(topic:) }
    topic.reload
    assert_not_equal old_token, topic.run_token
    assert_predicate topic, :queued?
    assert_nil topic.error_code
    assert_empty topic.discovery
    assert_empty topic.report
    assert_raises(Investigations::SubmitTopic::Conflict) { Investigations::SubmitTopic.restart(topic:) }
  end

  test "expired execution is failed rather than automatically spending another research attempt" do
    topic = Investigations::SubmitTopic.call(question: "Vacinas infantis")
    lease = topic.claim_execution!(run_token: topic.run_token)
    assert lease
    clear_enqueued_jobs
    travel 6.minutes do
      assert_no_enqueued_jobs { Investigations::RecoverTopicResearchJob.perform_now }
    end
    assert_predicate topic.reload, :failed?
    assert_equal "interrupted", topic.error_code
    assert_nil topic.lease_token
    assert topic.finished_at
  end

  test "live leases and terminal reports are left alone by recovery and cancellation" do
    topic = Investigations::SubmitTopic.call(question: "Vacinas infantis")
    topic.claim_execution!(run_token: topic.run_token)
    clear_enqueued_jobs
    assert_no_enqueued_jobs { Investigations::RecoverTopicResearchJob.perform_now }
    assert_predicate topic.reload, :researching?
    topic.update!(status: :completed, report: { "conclusion" => "Stored result" })
    assert_not topic.cancel!
    assert_predicate topic.reload, :completed?
  end

  test "questions remain immutable after submission and completion requires a report" do
    topic = Investigations::SubmitTopic.call(question: "Vacinas infantis")
    assert_raises(ActiveRecord::ReadonlyAttributeError) { topic.question = "Different question" }
    assert_not topic.update(status: :completed)
    assert_predicate topic.reload, :queued?
  end

  test "records created by internal callers preserve the same canonical question identity" do
    topic = TopicInvestigation.create!(question: "  Vacinas infantis \n")
    assert_equal "Vacinas infantis", topic.question
    assert_empty enqueued_jobs
  end

  test "competing real database connections cannot acquire the same execution" do
    topic = Investigations::SubmitTopic.call(question: "Vacinas infantis")
    id, run_token = topic.id, topic.run_token
    ready, start = Queue.new, Queue.new
    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          TopicInvestigation.find(id).claim_execution!(run_token:)
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    tokens = workers.map(&:value).compact
    assert_equal 1, tokens.size
    assert_equal tokens.sole, topic.reload.lease_token
    assert_predicate topic, :researching?
  end

  test "recovery is scheduled on queues consumed by both local and production workers" do
    recurring = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    queues = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/queue.yml"))).result, aliases: true)
    %w[development production].each do |environment|
      task = recurring.fetch(environment).fetch("recover_topic_research")
      assert_equal "Investigations::RecoverTopicResearchJob", task.fetch("class")
      assert_equal "every 5 minutes", task.fetch("schedule")
      consumed = queues.fetch(environment).fetch("workers").flat_map { |worker| Array(worker.fetch("queues")) }
      assert consumed.include?("*") || consumed.include?(task.fetch("queue"))
    end
  end

  test "assessment handoff is durable and recovered with the assessment job rather than another search" do
    topic = TopicInvestigation.create!(question: "Vacinas infantis", status: :awaiting_assessment)
    assert_enqueued_with(job: Investigations::AssessTopicJob, args: [ topic.id, topic.run_token ]) do
      assert Investigations::TopicResearchDelivery.dispatch(topic.id, topic.run_token)
    end
    assert_not Investigations::TopicResearchDelivery.dispatch(topic.id, topic.run_token)
    clear_enqueued_jobs
    travel 6.minutes do
      assert_enqueued_with(job: Investigations::AssessTopicJob) { Investigations::RecoverTopicResearchJob.perform_now }
    end
    refute enqueued_jobs.any? { |job| job[:job] == Investigations::DiscoverTopicJob }
  end
end
