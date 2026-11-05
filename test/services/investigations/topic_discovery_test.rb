require "test_helper"
require "cgi"

class Investigations::TopicDiscoveryTest < ActiveSupport::TestCase
  QUESTION = "O desmatamento na Amazônia caiu em 2024?"
  FIXTURES = Rails.root.join("test/fixtures/files/topic_discovery")

  # Payloads and source texts captured from the real subscription-backed POC.
  class ResearchModel
    attr_reader :calls, :responses
    attr_accessor :error

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    %i[plan screen classify].each do |stage|
      define_method(stage) do |**arguments|
        @calls << [ stage, arguments ]
        raise error if error
        @responses.fetch(stage).deep_dup
      end
    end
  end

  class Searcher
    attr_reader :calls, :answers

    def initialize(answers)
      @answers = answers
      @calls = []
    end

    def call(query:, max_results:)
      @calls << query
      @answers.fetch(query, []).first(max_results).map do |item|
        Fetchers::WebSearcher::SearchResult.new(**item.symbolize_keys)
      end
    end
  end

  class Fetcher
    attr_reader :calls
    attr_accessor :after_read, :error

    def initialize(documents)
      @documents = documents.index_by { |item| item.fetch("url") }
      @calls = []
    end

    def call(url)
      @calls << url
      raise error if error
      item = @documents.fetch(url) { raise Fetchers::ChromiumFetcher::FetchError, "unreadable page" }
      body = item.fetch("body").split("\n").reject(&:blank?).map { |text| "<p>#{CGI.escapeHTML(text)}</p>" }.join
      after_read&.call
      Fetchers::ChromiumFetcher::Snapshot.new(
        html: "<html><title>#{CGI.escapeHTML(item.fetch('title'))}</title><body><article>#{body}</article></body></html>",
        title: item.fetch("title")
      )
    end
  end

  setup do
    @responses = { plan: fixture("plan"), screen: fixture("screen"), classify: fixture("classification") }
    @model = ResearchModel.new(@responses)
    news = fixture("news_candidates")
    evidence = fixture("evidence_candidates")
    plan = @responses.fetch(:plan)
    screen = @responses.fetch(:screen)
    @searcher = Searcher.new(distributed(plan.fetch("news_queries"), news).merge(
      distributed((screen.fetch("evidence_queries") + plan.fetch("evidence_queries")).uniq, evidence)))
    @fetcher = Fetcher.new(fixture("documents"))
  end

  test "discovers and reads sources from generated queries and distinguishes news from producers and indexes" do
    stages = []
    result = discover(on_progress: ->(stage, _) { stages << stage })

    assert_equal QUESTION, result.fetch("question")
    assert_equal @responses[:plan]["scope"], result.fetch("scope")
    assert_equal %w[S2 S4], result.fetch("news_ids")
    assert_equal %w[S1 S3 S6 S7], result.fetch("producer_ids")
    assert_equal %w[S5 S8], result.fetch("excluded_ids")
    assert_equal 8, result.fetch("documents").size
    assert_equal "discovered", result.fetch("status")
    assert_equal %i[plan screen classify], @model.calls.map(&:first)
    assert_includes @searcher.calls, @responses[:screen]["evidence_queries"].first
    assert_operator @searcher.calls.size, :<=, 8
    assert_operator @fetcher.calls.size, :<=, 24
    assert_equal @fetcher.calls.uniq, @fetcher.calls
    assert_equal %w[planning searching_news reading_news screening searching_evidence reading_evidence classifying], stages.uniq
    assert result.fetch("documents").all? { |item| item.fetch("body").length >= 500 }
    assert result.fetch("documents").all? { |item| item.fetch("fetched_at").present? }
    assert result.fetch("failures").all? { |item| item.keys.sort == %w[reason url] }
    refute result.key?("verdict"), "retrieval alone must never produce a factual assessment"
  end

  test "one invalid source screen retries the same read documents without repeating retrieval" do
    model = @model
    original = model.method(:screen)
    attempts = []
    model.define_singleton_method(:screen) do |**arguments|
      attempts << arguments.deep_dup
      payload = original.call(**arguments)
      payload["reviews"].first["scope_quote"] = "This quotation is absent from the read source." if attempts.size == 1
      payload
    end
    result = discover
    assert_equal "discovered", result["status"]
    assert_equal 1, result["screening_retries"]
    assert_equal 2, attempts.size
    assert_equal attempts.first, attempts.last
    assert_equal @fetcher.calls.uniq, @fetcher.calls
  end

  test "two invalid screens remain a failure and never hand off unvalidated sources" do
    @model.responses[:screen]["reviews"].first["id"] = "S999"
    snapshots = []
    assert_raises(Investigations::TopicDiscovery::InvalidResponse) do
      discover(on_progress: ->(_, snapshot) { snapshots << snapshot })
    end
    assert_equal 2, @model.calls.count { |stage, _| stage == :screen }
    assert_equal 1, snapshots.last["screening_retries"]
    assert_empty snapshots.last["news_ids"]
    refute @model.calls.any? { |stage, _| stage == :classify }
  end

  test "cancellation after an invalid screen prevents a second model call" do
    cancelled = false
    model = @model
    original = model.method(:screen)
    model.define_singleton_method(:screen) do |**arguments|
      payload = original.call(**arguments)
      payload["reviews"].first["id"] = "S999"
      cancelled = true
      payload
    end
    assert_raises(Investigations::TopicDiscovery::Cancelled) { discover(cancelled: -> { cancelled }) }
    assert_equal 1, @model.calls.count { |stage, _| stage == :screen }
  end

  test "the single retry budget is shared across structured screening rounds" do
    @responses[:plan] = fixture("structured_plan").merge("news_queries" => %w[first second], "evidence_queries" => [ "evidence" ])
    docs = fixture("documents").first(7)
    candidates = docs.map { |item| item.slice("url", "title").merge("snippet" => "") }
    @searcher = Searcher.new({ "first" => candidates.first(5), "second" => candidates.drop(5) })
    attempts = 0
    @model.define_singleton_method(:screen) do |documents:, **|
      attempts += 1
      payload = { "reviews" => documents.map { |item| { "id" => item["id"], "relevant" => true, "reason" => "Requested captured subject", "scope_quote" => item["body"][0, 70] } }, "evidence_queries" => [] }
      payload["reviews"].first["id"] = "S999" if attempts.odd?
      payload
    end
    @model.define_singleton_method(:classify) do |documents:, **|
      { "documents" => documents.map { |item| { "id" => item["id"], "kind" => "news_article", "reason" => "Individual source", "quote" => item["body"][0, 70] } } }
    end
    assert_raises(Investigations::TopicDiscovery::InvalidResponse) { discover }
    assert_equal 3, attempts, "A later round must not receive a fresh retry allowance"
    assert_equal 7, @fetcher.calls.size
  end

  test "time exhaustion after invalid screening prevents the retry" do
    model = @model
    original = model.method(:screen)
    service = nil
    model.define_singleton_method(:screen) do |**arguments|
      payload = original.call(**arguments)
      payload["reviews"].first["id"] = "S999"
      service.instance_variable_set(:@deadline, 0)
      payload
    end
    service = Investigations::TopicDiscovery.new(question: QUESTION, model: @model, searcher: @searcher, fetcher: @fetcher)
    assert_raises(Investigations::TopicDiscovery::BudgetExceeded) { service.call }
    assert_equal 1, @model.calls.count { |stage, _| stage == :screen }
  end

  test "failed searches are retried once recorded and never treated as no news" do
    @searcher.define_singleton_method(:call_with_status) do |query:, max_results:|
      @calls << query
      Fetchers::WebSearcher::Outcome.new(results: [], status: "failed", error_code: "timeout")
    end
    snapshots = []
    assert_raises(Investigations::TopicDiscovery::SearchUnavailable) do
      discover(on_progress: ->(_, snapshot) { snapshots << snapshot })
    end
    assert_equal 4, @searcher.calls.size
    assert_equal 4, snapshots.last.fetch("searches").size
    assert_empty @fetcher.calls
  end

  test "a failed query does not discard results from an independent successful query" do
    first = @responses[:plan]["news_queries"].first
    @searcher.define_singleton_method(:call_with_status) do |query:, max_results:|
      if query == first
        @calls << query
        Fetchers::WebSearcher::Outcome.new(results: [], status: "failed", error_code: "blocked")
      else
        Fetchers::WebSearcher::Outcome.new(results: call(query:, max_results:), status: "success")
      end
    end
    # The pre-existing fixture corpus has source IDs tied to its complete input;
    # stop after retrieval to check the retained source text, not model answers.
    captured = nil
    @model.define_singleton_method(:screen) do |**args|
      captured = args.fetch(:documents)
      raise Investigations::TopicDiscovery::Cancelled
    end
    assert_raises(Investigations::TopicDiscovery::Cancelled) { discover }
    assert captured.any?
    assert_equal first, @searcher.calls.first
  end

  test "structured search replenishes unreadable news and keeps uncertain quota gaps explicit" do
    @responses[:plan] = fixture("structured_plan")
    @responses[:plan]["news_queries"] = [ "all candidates" ]
    @responses[:plan]["evidence_queries"] = [ "no evidence" ]
    docs = fixture("documents")
    @searcher = Searcher.new({ "all candidates" => [ { "url" => "https://missing.example.org/report", "title" => "blocked", "snippet" => "" } ] + docs.first(4).map { |item| item.slice("url", "title").merge("snippet" => "") } })
    @model.define_singleton_method(:screen) do |documents:, **|
      { "reviews" => documents.map { |item| { "id" => item["id"], "relevant" => true, "reason" => "Relevant captured scope", "scope_quote" => item["body"][0, 60] } }, "evidence_queries" => [] }
    end
    @model.define_singleton_method(:classify) do |documents:, **|
      { "documents" => documents.map { |item| { "id" => item["id"], "kind" => "news_article", "reason" => "Individual captured source", "quote" => item["body"][0, 60],
        "editorial_position" => "unknown", "editorial_confidence" => "unknown", "editorial_reason" => "No explicit editorial statement", "editorial_quote" => "" } } }
    end
    result = discover
    assert_equal "discovered", result.fetch("status")
    assert_equal 4, result.fetch("documents").size
    assert_equal 1, result.fetch("failures").size
    refute result.dig("selection", "coverage_complete")
    assert_equal 6, result.dig("selection", "missing").values.sum
    assert result.fetch("news_ids").any?
  end

  test "replacement candidates fulfill six quotas despite an early blocked page" do
    @responses[:plan] = fixture("structured_plan")
    @responses[:plan]["news_queries"] = %w[first second]
    @responses[:plan]["evidence_queries"] = [ "original evidence" ]
    sides = %w[left left center center right right]
    docs = sides.each_with_index.map do |side, index|
      { "url" => "https://publication#{index}.example.org/report", "title" => "Independent #{index}",
        "body" => "We explicitly identify our publication editorial perspective as #{side}. " + (1..100).map { |n| "report#{index}finding#{n}" }.join(" ") }
    end
    candidates = [ { "url" => "https://missing.example.org/report", "title" => "Blocked", "snippet" => "" } ] + docs.map { |item| item.slice("url", "title").merge("snippet" => "") }
    @searcher = Searcher.new({ "first" => candidates.first(5), "second" => candidates.drop(5) })
    @fetcher = Fetcher.new(docs)
    @model.define_singleton_method(:screen) do |documents:, **|
      { "reviews" => documents.map { |item| { "id" => item["id"], "relevant" => true, "reason" => "Requested subject and scope", "scope_quote" => item["body"][0, 70] } }, "evidence_queries" => [] }
    end
    @model.define_singleton_method(:classify) do |documents:, **|
      { "documents" => documents.map do |item|
        side = item["body"][/perspective as (left|center|right)/, 1]
        { "id" => item["id"], "kind" => "news_article", "reason" => "Individual report", "quote" => item["body"][0, 70],
          "editorial_position" => side, "editorial_confidence" => "documented", "editorial_reason" => "Publication explicitly self-identifies its perspective", "editorial_quote" => item["body"][0, 70] }
      end }
    end
    result = discover
    assert_equal 6, result.fetch("news_ids").size
    assert result.dig("selection", "coverage_complete")
    assert_equal 1, result.fetch("failures").size
    assert_equal 7, @fetcher.calls.size
  end

  test "documented editorial labels must cite this source rather than a politician or another source" do
    @responses[:classify] = fixture("structured_classification")
    item = @responses[:classify].fetch("documents").find { |entry| entry["kind"] == "news_article" }
    item.merge!("editorial_position" => "right", "editorial_confidence" => "documented", "editorial_reason" => "Publication explicitly declares its orientation", "editorial_quote" => "This literal declaration was never present in the body")
    assert_raises(Investigations::TopicDiscovery::InvalidResponse) { discover }
  end

  test "rejects invalid questions before any model search or browser call" do
    [ nil, [], {}, " ", "a" * 501, "12345" ].each do |question|
      assert_raises(Investigations::TopicDiscovery::InvalidQuestion) { discover(question:) }
    end
    assert_empty @model.calls
    assert_empty @searcher.calls
    assert_empty @fetcher.calls
  end

  test "rejects invalid generated queries rather than searching unbounded model output" do
    @responses[:plan]["news_queries"] = [ "a" * 301 ]
    assert_raises(Investigations::TopicDiscovery::InvalidResponse) { discover }
    assert_empty @searcher.calls
    assert_empty @fetcher.calls
  end

  test "empty search results are no news and not evidence against the question" do
    @searcher = Searcher.new({})
    result = discover
    assert_equal "no_news", result.fetch("status")
    assert_empty result.fetch("documents")
    assert_empty result.fetch("news_ids")
    assert_equal [ :plan ], @model.calls.map(&:first)
    refute result.key?("verdict")
  end

  test "an irrelevant read corpus stops before evidence searches and classification" do
    @responses[:screen]["reviews"].each do |item|
      item["relevant"] = false
      item["scope_quote"] = ""
    end
    result = discover
    assert_equal "no_news", result.fetch("status")
    assert_empty result.fetch("news_ids")
    assert_equal 2, @searcher.calls.size
    assert_equal %i[plan screen], @model.calls.map(&:first)
  end

  test "canonical URL aliases do not consume another article slot or create a second source identity" do
    news = fixture("news_candidates")
    alias_item = news.first.merge("url" => "#{news.first.fetch('url')}?utm_source=duplicate")
    plan = @responses[:plan]
    @searcher = Searcher.new(distributed(plan.fetch("news_queries"), news.first(2) + [ alias_item ] + news.drop(2)).merge(
      @responses[:screen].fetch("evidence_queries")[0] => fixture("evidence_candidates").first(5)))
    result = discover
    assert_equal %w[S2 S4], result.fetch("news_ids")
    assert_equal 1, @fetcher.calls.count(news.first.fetch("url"))
    assert_equal @fetcher.calls.uniq, @fetcher.calls
  end

  test "source text has a bounded length and truncation is recorded instead of concealed" do
    documents = fixture("documents")
    documents.first["body"] += "\n\n" + "More source context. " * 1000
    @fetcher = Fetcher.new(documents)
    result = discover
    document = result.fetch("documents").first
    assert_equal 14_000, document.fetch("body").length
    assert document.fetch("truncated")
    @model.calls.drop(1).each do |_, arguments|
      assert arguments.fetch(:documents).all? { |item| item.fetch("body").length <= 14_000 }
    end
  end

  test "unreadable pages remain explicit and are never replaced with snippets" do
    @fetcher = Fetcher.new([])
    result = discover
    assert_equal "no_news", result.fetch("status")
    assert_empty result.fetch("documents")
    assert_equal 8, result.fetch("failures").size
    assert result.fetch("failures").all? { |item| item.fetch("reason") == "fetch_failed" }
    assert_equal [ :plan ], @model.calls.map(&:first)
  end

  test "browser network status errors are source failures rather than aborting the whole research" do
    @fetcher.error = Ferrum::StatusError.new("https://example.com/unavailable")
    result = discover
    assert_equal "no_news", result.fetch("status")
    assert_empty result.fetch("documents")
    assert_equal 8, result.fetch("failures").size
    assert result.fetch("failures").all? { |item| item.fetch("reason") == "fetch_failed" }
  end

  test "an early query full of unreadable results cannot starve original sources found by another query" do
    queries = (@responses[:screen].fetch("evidence_queries") + @responses[:plan].fetch("evidence_queries")).uniq
    answers = @searcher.answers.merge(queries.index_with { [] })
    answers[queries[0]] = 5.times.map { |i| { "url" => "https://example.com/unreadable-#{i}.pdf", "title" => "Unreadable result", "snippet" => "" } }
    document = fixture("documents").find { |item| item.fetch("id") == "S6" }
    answers[queries[1]] = [ { "url" => document.fetch("url"), "title" => document.fetch("title"), "snippet" => "" } ]
    @searcher = Searcher.new(answers)
    @responses[:classify]["documents"].select! { |item| %w[S1 S2 S3 S4 S5 S6].include?(item.fetch("id")) }
    result = discover
    assert_includes result.fetch("producer_ids"), "S6"
    assert_equal document.fetch("url"), result.fetch("documents").last.fetch("url")
    assert_equal %w[S2 S4], result.fetch("news_ids")
  end

  test "legacy discovery replaces six blocked candidates with later readable results" do
    original = @searcher.answers
    queries = @responses[:plan].fetch("news_queries")
    blocked = 6.times.map { |i| { "url" => "https://blocked#{i}.example.org/report", "title" => "Blocked", "snippet" => "" } }
    news = fixture("news_candidates").first(2)
    @searcher = Searcher.new(original.merge(distributed(queries, blocked + news)))
    @model.define_singleton_method(:screen) do |documents:, **|
      { "reviews" => documents.map { |item| { "id" => item["id"], "relevant" => true, "reason" => "Captured scope", "scope_quote" => item["body"].first(60) } }, "evidence_queries" => [] }
    end
    @model.define_singleton_method(:classify) do |documents:, **|
      { "documents" => documents.map { |item| { "id" => item["id"], "kind" => "news_article", "reason" => "Captured article", "quote" => item["body"].first(60) } } }
    end
    result = discover
    assert_equal "discovered", result["status"]
    assert_equal 6, result["failures"].count { |item| item["url"].include?("blocked") }
    assert_includes result["documents"].pluck("url"), news.last["url"]
    assert_equal 1, result.fetch("additional_evidence_rounds")
    assert_operator result.dig("budget", "read_attempts"), :<=, 24
  end

  test "subscription shells are rejected even when they exceed the minimum text length" do
    docs = fixture("documents")
    blocked = docs.first["url"]
    docs.first["body"] = "Assine assinatura assinante conteúdo exclusivo. " * 20
    @fetcher = Fetcher.new(docs)
    # Stop after retrieval to isolate shell filtering from captured fixed source IDs.
    snapshots = []
    stopped = false
    assert_raises(Investigations::TopicDiscovery::Cancelled) do
      discover(cancelled: -> { stopped }, on_progress: lambda { |stage, snapshot|
        snapshots << snapshot
        stopped = stage == "screening"
      })
    end
    assert snapshots.last["failures"].any? { |item| item["url"] == blocked && item["reason"] == "insufficient_text" }
    refute_includes snapshots.last["documents"].pluck("url"), blocked
    assert_includes @fetcher.calls, blocked
    refute_includes @model.calls.map(&:first), :screen
  end

  test "cancellation during the additional round prevents further calls" do
    stopped = false
    assert_raises(Investigations::TopicDiscovery::Cancelled) do
      discover(cancelled: -> { stopped }, on_progress: ->(_, snapshot) { stopped = true if snapshot["additional_evidence_rounds"] == 1 })
    end
    assert_equal 6, @searcher.calls.size
  end

  test "finding a producer without read failures still checks possible contradictions once" do
    @searcher = fully_readable_searcher
    result = discover
    assert_empty result["failures"]
    assert result["producer_ids"].any?
    assert_equal 1, result["additional_evidence_rounds"]
    assert @searcher.calls.any? { |query| query.include?("correction") }
    assert_operator result.dig("budget", "search_attempts"), :<=, 28
    assert_equal %w[S2 S4], result["news_ids"]
  end

  test "counter-evidence queries retain literal names geography and period at the length limit" do
    prefix = '"Projeto de Medição '
    suffix = ' Brasil 2024 Amazônia Legal"'
    query = prefix + "x" * (300 - prefix.length - suffix.length) + suffix
    @responses[:screen]["evidence_queries"][0] = query
    @searcher = fully_readable_searcher
    result = discover
    assert_equal 300, query.length
    assert_equal 2, @searcher.calls.count(query), "a length-limited directed query must be preserved verbatim rather than truncated"
    assert @searcher.calls.all? { |item| item.length <= 300 }
    assert_equal 1, result["additional_evidence_rounds"]
    assert_empty result["failures"]
  end

  test "elapsed budget stops after a slow read without publishing it" do
    elapsed = 0
    @fetcher.after_read = -> { elapsed = 2000 }
    assert_raises(Investigations::TopicDiscovery::BudgetExceeded) { discover(clock: -> { elapsed }) }
    assert_equal 1, @fetcher.calls.size
    assert_equal [ :plan ], @model.calls.map(&:first)
  end

  test "private search result URLs are rejected before opening a browser" do
    first_query = @responses[:plan].fetch("news_queries").first
    @searcher = Searcher.new(first_query => [ { "url" => "http://127.0.0.1/private", "title" => "private", "snippet" => "" } ])
    result = discover
    assert_empty @fetcher.calls
    assert_equal "unsafe_url", result.fetch("failures").sole.fetch("reason")
    assert_equal "no_news", result.fetch("status")
  end

  test "source identity is checked for missing duplicate and invented screen IDs" do
    original = @responses[:screen].deep_dup
    [ original.fetch("reviews").drop(1), original.fetch("reviews") + [ original.fetch("reviews").first ],
      original.fetch("reviews").map { |item| item.merge("id" => "unknown") } ].each do |reviews|
      @responses[:screen] = original.merge("reviews" => reviews)
      assert_raises(Investigations::TopicDiscovery::InvalidResponse) { discover }
    end
    refute_includes @model.calls.map(&:first), :classify
  end

  test "scope claims must cite an exact passage from that source and not another document" do
    @responses[:screen]["reviews"][1]["scope_quote"] = @responses[:screen]["reviews"][0]["scope_quote"]
    assert_raises(Investigations::TopicDiscovery::InvalidResponse) { discover }
    refute_includes @model.calls.map(&:first), :classify
  end

  test "classification cannot invent omit or duplicate a source or quote" do
    original = @responses[:classify].deep_dup
    mutations = [
      original.fetch("documents").drop(1),
      original.fetch("documents") + [ original.fetch("documents").first ],
      original.fetch("documents").map { |item| item.merge("id" => "unknown") },
      original.fetch("documents").map { |item| item.merge("quote" => "a quotation the source does not contain") }
    ]
    mutations.each do |items|
      @responses[:classify] = original.merge("documents" => items)
      assert_raises(Investigations::TopicDiscovery::InvalidResponse) { discover }
    end
  end

  test "cancellation before starting makes no calls" do
    assert_raises(Investigations::TopicDiscovery::Cancelled) { discover(cancelled: -> { true }) }
    assert_empty @model.calls
    assert_empty @searcher.calls
    assert_empty @fetcher.calls
  end

  test "cancellation during a fetch stops before screening or publishing its document" do
    cancelled = false
    snapshots = []
    @fetcher.after_read = -> { cancelled = true }
    assert_raises(Investigations::TopicDiscovery::Cancelled) do
      discover(cancelled: -> { cancelled }, on_progress: ->(_, snapshot) { snapshots << snapshot })
    end
    assert_equal 1, @fetcher.calls.size
    assert_equal [ :plan ], @model.calls.map(&:first)
    assert snapshots.all? { |snapshot| snapshot.fetch("documents").empty? }
  end

  test "progress consumers cannot alter the source text used by later model calls" do
    result = discover(on_progress: lambda { |_, snapshot|
      snapshot.fetch("documents").each { |item| item["body"] = "tampered" }
    })
    assert_equal %w[S2 S4], result.fetch("news_ids")
    refute result.fetch("documents").any? { |item| item.fetch("body") == "tampered" }
  end

  test "model errors propagate instead of producing heuristic verdicts or changing providers" do
    @model.error = Llm::Chatgpt::Error.new("usage_limit_reached")
    assert_raises(Llm::Chatgpt::Error) { discover }
    assert_empty @searcher.calls
    assert_empty @fetcher.calls
    assert_equal [ :plan ], @model.calls.map(&:first)
  end

  private

  def fixture(name)
    JSON.parse(File.read(FIXTURES.join("#{name}.json")))
  end

  def distributed(queries, results)
    queries.each_with_index.to_h { |query, index| [ query, results.each_slice(queries.size).filter_map { |slice| slice[index] } ] }
  end

  def fully_readable_searcher
    documents = fixture("documents")
    candidates = documents.map { |item| item.slice("url", "title").merge("snippet" => "") }
    queries = (@responses[:screen]["evidence_queries"] + @responses[:plan]["evidence_queries"]).uniq
    Searcher.new(distributed(@responses[:plan]["news_queries"], candidates.first(5)).merge(distributed(queries, candidates.drop(5))))
  end

  def discover(question: QUESTION, **options)
    Investigations::TopicDiscovery.new(question:, model: @model, searcher: @searcher, fetcher: @fetcher, **options).call
  end
end
