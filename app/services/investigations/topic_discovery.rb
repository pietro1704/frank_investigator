require "set"
require "timeout"

module Investigations
  # Retrieves and identifies source documents. It deliberately issues no verdict:
  # relevance, provenance and an exact quotation do not establish factual truth.
  class TopicDiscovery
    class InvalidQuestion < ArgumentError; end
    class InvalidResponse < StandardError; end
    class Cancelled < StandardError; end
    class Unavailable < StandardError; end
    class SearchUnavailable < StandardError; end
    class BudgetExceeded < StandardError; end

    MAX_QUESTION_LENGTH = 500
    MAX_NEWS_PAGES = 6
    MAX_EVIDENCE_PAGES = 4
    MAX_READ_PAGES = 28
    MAX_READ_ATTEMPTS = 36
    MAX_SEARCH_ATTEMPTS = 28
    MAX_BODY_LENGTH = 14_000
    MIN_BODY_LENGTH = 500
    DOCUMENT_KINDS = %w[news_article producer_publication index_or_other].freeze

    def self.call(question:, **options)
      new(question:, **options).call
    end

    def self.normalize_question(question)
      unless question.is_a?(String) && question.strip.length.between?(1, MAX_QUESTION_LENGTH) && question.match?(/\p{L}/)
        raise InvalidQuestion
      end
      question.strip
    end

    def initialize(question:, model: ResearchModel.new, searcher: Fetchers::WebSearcher,
      fetcher: Fetchers::ChromiumFetcher, cancelled: -> { false }, on_progress: ->(*) { }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @question = self.class.normalize_question(question)
      @model, @searcher, @fetcher = model, searcher, fetcher
      @cancelled, @on_progress, @clock = cancelled, on_progress, clock
      @visited = Set.new
      @timeout_seconds = ENV.fetch("FRANK_TOPIC_TIMEOUT_SECONDS", 900).to_i.clamp(30, 1800)
      @deadline = @clock.call + @timeout_seconds
      @result = { "budget" => { "seconds" => @timeout_seconds, "max_read_pages" => MAX_READ_PAGES, "max_read_attempts" => MAX_READ_ATTEMPTS,
          "max_search_attempts" => MAX_SEARCH_ATTEMPTS, "read_attempts" => 0, "search_attempts" => 0 },
        "question" => @question, "status" => "discovering", "scope" => nil,
        "documents" => [], "failures" => [], "searches" => [], "news_ids" => [], "producer_ids" => [], "excluded_ids" => [] }
    end

    def call
      Timeout.timeout(@timeout_seconds, BudgetExceeded) { discover }
    end

    private

    def discover
      progress("planning")
      plan = TopicPlan.call(@model.plan(question: @question))
      validate_plan!(plan)
      @result.merge!("plan" => plan, "scope" => plan.fetch("scope"))

      return structured_discovery(plan) if plan.fetch("version") == 2

      progress("searching_news")
      candidates = search(plan.fetch("news_queries"), stage: "searching_news")
      read(candidates, role: "news", limit: 12, successful_limit: MAX_NEWS_PAGES)
      return no_news if documents.empty?

      progress("screening")
      screen = screen_documents!
      @result["screen"] = screen
      relevant_ids = screen.fetch("reviews").select { |review| review.fetch("relevant") }.pluck("id")
      return no_news if relevant_ids.empty?

      progress("searching_evidence")
      queries = (screen.fetch("evidence_queries") + plan.fetch("evidence_queries")).uniq.first(4)
      candidates = search(queries, stage: "searching_evidence")
      read(candidates, role: "evidence", limit: 8, successful_limit: MAX_EVIDENCE_PAGES)

      classify_documents!
      set_evidence_ids!
      @result["news_ids"] = relevant_ids.select { |id| documents.find { |item| item["id"] == id }["kind"] == "news_article" }
      replenish_evidence!(plan, screen)
      @result["news_ids"] = relevant_ids.select { |id| documents.find { |item| item["id"] == id }["kind"] == "news_article" }
      check_cancelled!
      @result["status"] = @result.fetch("news_ids").any? ? "discovered" : "no_news"
      @result
    end

    private

    def structured_discovery(plan)
      progress("searching_news")
      candidates = search(TopicEditorialProfiles.queries(plan), stage: "searching_news")
      attempts = ENV.fetch("FRANK_TOPIC_NEWS_ATTEMPTS", 24).to_i.clamp(6, 24)
      screen = nil
      relevant_ids = []
      resolver = nil
      if plan.dig("requirements", "editorial_counts").values.sum.positive? && @model.respond_to?(:editorial_profile)
        resolver = TopicEditorialProfiles.new(model: @model, fetcher: @fetcher, on_progress: lambda {
          @result["editorial_profiles"] = resolver.profiles.deep_dup
          progress("profiling_editorial")
        })
      end
      remaining = candidates.first(attempts)
      until remaining.empty?
        if resolver && @result["selection"]
          remaining = remaining.sort_by { |candidate| resolver.priority(candidate, @result["selection"]["missing"]) }
        end
        batch = remaining.shift(6)
        read(batch, role: "news", limit: 6)
        next if documents.empty?
        progress("screening")
        screen = screen_documents!
        @result["screen"] = screen
        relevant_ids = screen.fetch("reviews").select { |item| item.fetch("relevant") }.pluck("id")
        classify_documents!
        documents.each { |document| resolver.enrich(document) } if resolver
        select_documents!(relevant_ids, plan)
        break if @result.dig("selection", "coverage_complete")
      end
      return no_news if documents.empty?
      progress("searching_evidence")
      queries = (Array(screen&.fetch("evidence_queries")) + plan.fetch("evidence_queries")).uniq.first(4)
      evidence = search(queries, stage: "searching_evidence")
      read(evidence, role: "evidence", limit: 8, successful_limit: MAX_EVIDENCE_PAGES)
      classify_documents!
      documents.each { |document| resolver.enrich(document) } if resolver
      select_documents!(relevant_ids, plan)
      replenish_evidence!(plan, screen)
      documents.each { |document| resolver.enrich(document) } if resolver
      select_documents!(relevant_ids, plan)
      @result["status"] = @result.fetch("news_ids").any? ? "discovered" : "no_news"
      progress("classifying")
      @result
    end

    def set_evidence_ids!
      @result["producer_ids"] = documents.select { |item| item["kind"] == "producer_publication" }.pluck("id")
      @result["excluded_ids"] = documents.select { |item| item["kind"] == "index_or_other" }.pluck("id")
    end

    # One bounded round, aimed at missing originals and possible counter-evidence.
    # A producer label is a retrieval signal, never proof of a claim.
    def replenish_evidence!(plan, screen)
      return if @result["news_ids"].empty?
      @result["additional_evidence_rounds"] = 1
      progress("searching_evidence")
      used = @result["searches"].pluck("query")
      queries = (Array(screen&.fetch("evidence_queries")) + plan.fetch("evidence_queries")).reject { |query| used.include?(query) }
      bases = Array(screen&.fetch("evidence_queries")).presence || plan.fetch("evidence_queries")
      suffix = " original document corrections contradictory evidence"
      queries += bases.map { |query| query.length + suffix.length <= 300 ? query + suffix : query }
      candidates = search(queries.uniq.first(2), stage: "searching_evidence")
      previous_size = documents.size
      read(candidates, role: "evidence", limit: 4, successful_limit: 2)
      classify_documents! if documents.size > previous_size
      set_evidence_ids!
      @result["retrieval_limited"] = true if @result["producer_ids"].empty? || @result["failures"].any?
    end

    def screen_documents!
      check_cancelled!
      screen = @model.screen(question: @question, scope: @result.fetch("scope"), documents: documents.deep_dup)
      validate_screen!(screen)
      screen
    rescue InvalidResponse
      raise if @result.fetch("screening_retries", 0) >= 1
      @result["screening_retries"] = 1
      progress("screening")
      retry
    end

    def classify_documents!
      progress("classifying")
      classification = @model.classify(question: @question, documents: documents.map { |item| item.except("editorial_profile", "editorial_position", "editorial_confidence", "editorial_reason", "editorial_quote") }.deep_dup)
      validate_classification!(classification)
      @result["classification"] = classification
      by_id = classification.fetch("documents").index_by { |item| item.fetch("id") }
      documents.each do |document|
        item = by_id.fetch(document.fetch("id"))
        document.delete("editorial_profile")
        document.merge!(item.slice("kind", "editorial_position", "editorial_confidence", "editorial_reason", "editorial_quote"))
      end
    end

    def select_documents!(relevant_ids, plan)
      @result["selection"] = TopicSourceSelection.call(documents:, relevant_ids:,
        editorial_counts: plan.dig("requirements", "editorial_counts"), news_count: plan.dig("requirements", "news_count").to_i)
      @result["news_ids"] = @result.fetch("selection").fetch("news_ids")
      @result["producer_ids"] = documents.select { |item| item["kind"] == "producer_publication" }.pluck("id")
      @result["excluded_ids"] = documents.select { |item| item["kind"] == "index_or_other" }.pluck("id")
    end

    def documents
      @result.fetch("documents")
    end

    def check_cancelled!
      raise Cancelled if @cancelled.call
      raise BudgetExceeded if @clock.call > @deadline
    end

    def progress(stage)
      check_cancelled!
      @on_progress.call(stage, @result.deep_dup)
      check_cancelled!
    end

    def no_news
      check_cancelled!
      @result["status"] = "no_news"
      @result
    end

    def search(queries, stage:)
      successful = 0
      pages = queries.map do |query|
        results = []
        2.times do |attempt|
          check_cancelled!
          break if @result["budget"]["search_attempts"] >= MAX_SEARCH_ATTEMPTS
          @result["budget"]["search_attempts"] += 1
          outcome = if @searcher.respond_to?(:call_with_status)
            @searcher.call_with_status(query:, max_results: 5)
          else
            Fetchers::WebSearcher::Outcome.new(results: @searcher.call(query:, max_results: 5), status: "success")
          end
          check_cancelled!
          @result.fetch("searches") << { "query" => query, "status" => outcome.status,
            "error_code" => outcome.error_code, "attempt" => attempt + 1 }
          progress(stage)
          if outcome.status == "success"
            successful += 1
            results = outcome.results.first(5)
            break
          end
          break unless outcome.error_code.in?(%w[timeout unavailable])
        end
        results
      end
      raise SearchUnavailable if successful.zero? && documents.empty?
      pages.map(&:size).max.to_i.times.flat_map { |index| pages.filter_map { |page| page[index] } }.uniq(&:url)
    end

    def read(candidates, role:, limit:, successful_limit: nil)
      stage = role == "news" ? "reading_news" : "reading_evidence"
      progress(stage)
      attempts = 0
      initial_size = documents.size
      candidates.each do |candidate|
        check_cancelled!
        break if documents.size >= MAX_READ_PAGES || @result["budget"]["read_attempts"] >= MAX_READ_ATTEMPTS || attempts >= limit || (successful_limit && documents.size - initial_size >= successful_limit)
        next if @visited.include?(candidate.url)

        @visited.add(candidate.url)
        attempts += 1
        @result["budget"]["read_attempts"] += 1
        begin
          url = UrlNormalizer.call(candidate.url)
          raise UrlNormalizer::InvalidUrlError if URI.parse(url).userinfo.present?
          next if url != candidate.url && @visited.include?(url)
          @visited.add(url)
          check_cancelled!
          snapshot = @fetcher.call(url)
          check_cancelled!
          parsed = Parsing::MainContentExtractor.call(html: snapshot.html, url:)
          quality = Parsing::ContentQualityGate.call(body_text: parsed.body_text, title: parsed.title, url:)
          if parsed.body_text.to_s.length < MIN_BODY_LENGTH || !quality.pass
            @result.fetch("failures") << { "url" => url, "reason" => "insufficient_text" }
          else
            check_cancelled!
            documents << { "id" => "S#{documents.size + 1}", "url" => url, "title" => parsed.title,
              "body" => parsed.body_text.to_s.first(MAX_BODY_LENGTH), "fetched_at" => Time.current.iso8601,
              "truncated" => parsed.body_text.to_s.length > MAX_BODY_LENGTH, "candidate_role" => role,
              "publisher_pages" => TopicEditorialProfiles.publisher_pages(snapshot.html, url) }
          end
        rescue UrlNormalizer::InvalidUrlError
          @result.fetch("failures") << { "url" => candidate.url, "reason" => "unsafe_url" }
        rescue Fetchers::ChromiumFetcher::FetchError, Ferrum::StatusError, Timeout::Error
          @result.fetch("failures") << { "url" => candidate.url, "reason" => "fetch_failed" }
        end
        progress(stage)
      end
    end

    def object!(value, keys)
      raise InvalidResponse unless value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def text!(value, max:, min: 1)
      raise InvalidResponse unless value.is_a?(String) && value.strip.length.between?(min, max)
    end

    def queries!(value, min: 0, max: 2)
      raise InvalidResponse unless value.is_a?(Array) && value.size.between?(min, max)
      value.each { |query| text!(query, max: 300) }
    end

    def validate_plan!(plan)
      object!(plan, %w[scope news_queries evidence_queries requirements version])
      text!(plan.fetch("scope"), max: 2000)
      queries!(plan.fetch("news_queries"), min: 1, max: plan.fetch("version") == 2 ? 8 : 2)
      queries!(plan.fetch("evidence_queries"), min: 1)
      check_cancelled!
    end

    def identities!(items)
      raise InvalidResponse unless items.is_a?(Array) && items.all? { |item| item.is_a?(Hash) && item["id"].is_a?(String) }
      raise InvalidResponse unless items.pluck("id").sort == documents.pluck("id").sort
    end

    def grounded_quote!(item, field)
      quote = item.fetch(field)
      text!(quote, min: 20, max: MAX_BODY_LENGTH)
      document = documents.find { |source| source.fetch("id") == item.fetch("id") }
      raise InvalidResponse unless document.fetch("body").squish.include?(quote.squish)
    end

    def validate_screen!(screen)
      object!(screen, %w[reviews evidence_queries])
      reviews = screen.fetch("reviews")
      identities!(reviews)
      queries!(screen.fetch("evidence_queries"))
      reviews.each do |review|
        object!(review, %w[id relevant reason scope_quote])
        text!(review.fetch("reason"), max: 2000)
        raise InvalidResponse unless [ true, false ].include?(review.fetch("relevant"))
        if review.fetch("relevant")
          grounded_quote!(review, "scope_quote")
        else
          text!(review.fetch("scope_quote"), min: 0, max: MAX_BODY_LENGTH)
        end
      end
      check_cancelled!
    end

    def validate_classification!(classification)
      object!(classification, %w[documents])
      identities!(classification.fetch("documents"))
      classification.fetch("documents").each do |item|
        base = %w[id kind reason quote]
        editorial = %w[editorial_position editorial_confidence editorial_reason editorial_quote]
        raise InvalidResponse unless [ base.sort, (base + editorial).sort ].include?(item.keys.sort)
        if item.key?("editorial_position")
          raise InvalidResponse unless %w[left center right unknown].include?(item["editorial_position"]) &&
            %w[documented provisional unknown].include?(item["editorial_confidence"])
          text!(item["editorial_reason"], max: 2000, min: 0)
          text!(item["editorial_quote"], max: 2000, min: 0)
          if item["editorial_confidence"] == "documented"
            raise InvalidResponse unless item["kind"] == "news_article" && item["editorial_position"] != "unknown"
            grounded_quote!(item, "editorial_quote")
            text!(item["editorial_reason"], max: 2000, min: 20)
          end
        end
        raise InvalidResponse unless DOCUMENT_KINDS.include?(item.fetch("kind"))
        text!(item.fetch("reason"), max: 2000)
        grounded_quote!(item, "quote")
      end
    end
  end
end
