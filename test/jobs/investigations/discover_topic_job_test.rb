require "test_helper"

class Investigations::DiscoverTopicJobTest < ActiveJob::TestCase
  QUESTION = "O desmatamento na Amazônia caiu em 2024?"

  setup do
    @topic = TopicInvestigation.create!(question: QUESTION)
    @result = JSON.parse(File.read(Rails.root.join("test/fixtures/files/topic_discovery/discovered.json")))
    @calls = 0
  end

  test "persists source discovery without calling it a completed factual report" do
    callback = lambda do |**options|
      options.fetch(:on_progress).call("reading_news", @result)
      @result
    end
    with_discovery(callback) { perform }
    @topic.reload
    assert_predicate @topic, :awaiting_assessment?
    assert_equal "awaiting_assessment", @topic.stage
    assert_equal @result, @topic.discovery
    assert_empty @topic.report
    assert_nil @topic.finished_at
    assert_nil @topic.lease_token
    assert_nil @topic.lease_expires_at
    assert_equal 1, @calls
  end

  test "no news is terminal but does not manufacture a factual verdict" do
    @result.merge!("status" => "no_news", "news_ids" => [])
    with_discovery(->(**) { @result }) { perform }
    @topic.reload
    assert_predicate @topic, :no_news?
    assert @topic.finished_at
    assert_empty @topic.report
  end

  test "duplicate job delivery does not run source discovery twice" do
    with_discovery(->(**) { @result }) do
      perform
      perform
    end
    assert_equal 1, @calls
    assert_predicate @topic.reload, :awaiting_assessment?
  end

  test "foreign generation tokens and missing records never invoke discovery" do
    other = TopicInvestigation.create!(question: "Outra pergunta")
    with_discovery(->(**) { @result }) do
      Investigations::DiscoverTopicJob.perform_now(@topic.id, other.run_token)
      Investigations::DiscoverTopicJob.perform_now(-1, @topic.run_token)
    end
    assert_equal 0, @calls
    assert_predicate @topic.reload, :queued?
    assert_empty @topic.discovery
  end

  test "cancelling a queued topic prevents all research" do
    assert @topic.cancel!
    with_discovery(->(**) { @result }) { perform }
    assert_equal 0, @calls
    assert_predicate @topic.reload, :cancelled?
  end

  test "cancelling during research fences late progress and completion" do
    callback = lambda do |**options|
      @topic.cancel!
      assert options.fetch(:cancelled).call
      options.fetch(:on_progress).call("reading_evidence", @result)
      @result
    end
    with_discovery(callback) { perform }
    assert_predicate @topic.reload, :cancelled?
    assert_empty @topic.discovery
    assert_empty @topic.report
  end

  test "a non-cooperative late completion cannot revive a cancelled investigation" do
    callback = lambda do |**|
      @topic.cancel!
      @result
    end
    with_discovery(callback) { perform }
    assert_predicate @topic.reload, :cancelled?
    assert_empty @topic.discovery
    assert_empty @topic.report
  end

  test "a retried generation cannot be overwritten by the old running job" do
    old_token = @topic.run_token
    callback = lambda do |**options|
      @topic.cancel!
      Investigations::SubmitTopic.restart(topic: @topic)
      assert_not_equal old_token, @topic.reload.run_token
      options.fetch(:on_progress).call("classifying", @result)
      @result
    end
    with_discovery(callback) { Investigations::DiscoverTopicJob.perform_now(@topic.id, old_token) }
    assert_predicate @topic.reload, :queued?
    assert_empty @topic.discovery
    assert_empty @topic.report
  end

  test "late failure from an old generation cannot fail the new attempt" do
    callback = lambda do |**|
      @topic.cancel!
      Investigations::SubmitTopic.restart(topic: @topic)
      raise "old worker failure"
    end
    with_discovery(callback) { perform }
    assert_predicate @topic.reload, :queued?
    assert_nil @topic.error_code
    assert_empty @topic.discovery
  end

  test "quota failure stays explicit and duplicate delivery does not automatically retry it" do
    callback = ->(**) { raise Llm::Chatgpt::Error.new("subscription_sharing_usage_limit_exceeded") }
    with_discovery(callback) do
      perform
      perform
    end
    assert_predicate @topic.reload, :failed?
    assert_equal "usage_limit", @topic.error_code
    assert_equal 1, @calls
    assert_nil @topic.lease_token
    assert @topic.finished_at
    assert_empty @topic.report
  end

  test "wrong-question progress is rejected and never persisted in another report" do
    foreign = @result.merge("question" => "Private unrelated question")
    callback = ->(**options) { options.fetch(:on_progress).call("screening", foreign); @result }
    with_discovery(callback) { perform }
    assert_predicate @topic.reload, :failed?
    assert_equal "invalid_result", @topic.error_code
    assert_empty @topic.discovery
  end

  test "wrong-question or fabricated final discovery status cannot mark a topic complete" do
    [ @result.merge("question" => "Another question"), @result.merge("status" => "completed") ].each do |invalid|
      topic = TopicInvestigation.create!(question: QUESTION)
      with_discovery(->(**) { invalid }) { Investigations::DiscoverTopicJob.perform_now(topic.id, topic.run_token) }
      assert_predicate topic.reload, :failed?
      assert_equal "invalid_result", topic.error_code
      assert_empty topic.discovery
      assert_empty topic.report
    end
  end

  private

  def perform
    Investigations::DiscoverTopicJob.perform_now(@topic.id, @topic.run_token)
  end

  def with_discovery(callback = nil, &test)
    original = Investigations::TopicDiscovery.method(:call)
    callback ||= ->(**) { @result }
    owner = self
    Investigations::TopicDiscovery.define_singleton_method(:call) do |**options|
      owner.instance_variable_set(:@calls, owner.instance_variable_get(:@calls) + 1)
      callback.call(**options)
    end
    test.call
  ensure
    Investigations::TopicDiscovery.define_singleton_method(:call, original) if original
  end
end
