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
    assert_operator @searcher.calls.size, :<=, 6
    assert_operator @fetcher.calls.size, :<=, 10
    assert_equal @fetcher.calls.uniq, @fetcher.calls
    assert_equal %w[planning searching_news reading_news screening searching_evidence reading_evidence classifying], stages.uniq
    assert result.fetch("documents").all? { |item| item.fetch("body").length >= 500 }
    assert result.fetch("documents").all? { |item| item.fetch("fetched_at").present? }
    assert result.fetch("failures").all? { |item| item.keys.sort == %w[reason url] }
    refute result.key?("verdict"), "retrieval alone must never produce a factual assessment"
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
    assert_equal 6, result.fetch("failures").size
    assert result.fetch("failures").all? { |item| item.fetch("reason") == "fetch_failed" }
    assert_equal [ :plan ], @model.calls.map(&:first)
  end

  test "browser network status errors are source failures rather than aborting the whole research" do
    @fetcher.error = Ferrum::StatusError.new("https://example.com/unavailable")
    result = discover
    assert_equal "no_news", result.fetch("status")
    assert_empty result.fetch("documents")
    assert_equal 6, result.fetch("failures").size
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

  def discover(question: QUESTION, **options)
    Investigations::TopicDiscovery.new(question:, model: @model, searcher: @searcher, fetcher: @fetcher, **options).call
  end
end
