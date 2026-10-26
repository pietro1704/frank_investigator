require "set"

module Investigations
  # Retrieves and identifies source documents. It deliberately issues no verdict:
  # relevance, provenance and an exact quotation do not establish factual truth.
  class TopicDiscovery
    class InvalidQuestion < ArgumentError; end
    class InvalidResponse < StandardError; end
    class Cancelled < StandardError; end
    class Unavailable < StandardError; end

    MAX_QUESTION_LENGTH = 500
    MAX_NEWS_PAGES = 6
    MAX_EVIDENCE_PAGES = 4
    MAX_BODY_LENGTH = 14_000
    MIN_BODY_LENGTH = 500
    DOCUMENT_KINDS = %w[news_article producer_publication index_or_other].freeze

    def self.call(question:, **options)
      new(question:, **options).call
    end

    def initialize(question:, model: ResearchModel.new, searcher: Fetchers::WebSearcher,
      fetcher: Fetchers::ChromiumFetcher, cancelled: -> { false }, on_progress: ->(*) { })
      unless question.is_a?(String) && question.strip.length.between?(1, MAX_QUESTION_LENGTH) && question.match?(/\p{L}/)
        raise InvalidQuestion
      end

      @question = question.strip
      @model, @searcher, @fetcher = model, searcher, fetcher
      @cancelled, @on_progress = cancelled, on_progress
      @visited = Set.new
      @result = { "question" => @question, "status" => "discovering", "scope" => nil,
        "documents" => [], "failures" => [], "news_ids" => [], "producer_ids" => [], "excluded_ids" => [] }
    end

    def call
      progress("planning")
      plan = @model.plan(question: @question)
      validate_plan!(plan)
      @result.merge!("plan" => plan, "scope" => plan.fetch("scope"))

      progress("searching_news")
      candidates = search(plan.fetch("news_queries"))
      read(candidates, role: "news", limit: MAX_NEWS_PAGES)
      return no_news if documents.empty?

      progress("screening")
      screen = @model.screen(question: @question, scope: @result.fetch("scope"), documents: documents.deep_dup)
      validate_screen!(screen)
      @result["screen"] = screen
      relevant_ids = screen.fetch("reviews").select { |review| review.fetch("relevant") }.pluck("id")
      return no_news if relevant_ids.empty?

      progress("searching_evidence")
      queries = (screen.fetch("evidence_queries") + plan.fetch("evidence_queries")).uniq.first(4)
      candidates = search(queries)
      read(candidates, role: "evidence", limit: MAX_EVIDENCE_PAGES)

      progress("classifying")
      classification = @model.classify(question: @question, documents: documents.deep_dup)
      validate_classification!(classification)
      @result["classification"] = classification
      kinds = classification.fetch("documents").index_by { |item| item.fetch("id") }
      documents.each { |item| item["kind"] = kinds.fetch(item.fetch("id")).fetch("kind") }
      @result["news_ids"] = relevant_ids.select { |id| kinds.fetch(id).fetch("kind") == "news_article" }
      @result["producer_ids"] = documents.select { |item| item.fetch("kind") == "producer_publication" }.pluck("id")
      @result["excluded_ids"] = documents.select { |item| item.fetch("kind") == "index_or_other" }.pluck("id")
      check_cancelled!
      @result["status"] = @result.fetch("news_ids").any? ? "discovered" : "no_news"
      @result
    end

    private

    def documents
      @result.fetch("documents")
    end

    def check_cancelled!
      raise Cancelled if @cancelled.call
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

    def search(queries)
      queries.flat_map do |query|
        check_cancelled!
        results = @searcher.call(query:, max_results: 5)
        check_cancelled!
        results.first(5)
      end.uniq(&:url)
    end

    def read(candidates, role:, limit:)
      stage = role == "news" ? "reading_news" : "reading_evidence"
      progress(stage)
      attempts = 0
      candidates.each do |candidate|
        check_cancelled!
        break if attempts >= limit
        next if @visited.include?(candidate.url)

        @visited.add(candidate.url)
        begin
          url = UrlNormalizer.call(candidate.url)
          raise UrlNormalizer::InvalidUrlError if URI.parse(url).userinfo.present?
          next if url != candidate.url && @visited.include?(url)
          @visited.add(url)
          attempts += 1
          check_cancelled!
          snapshot = @fetcher.call(url)
          check_cancelled!
          parsed = Parsing::MainContentExtractor.call(html: snapshot.html, url:)
          if parsed.body_text.to_s.length < MIN_BODY_LENGTH
            @result.fetch("failures") << { "url" => url, "reason" => "insufficient_text" }
          else
            check_cancelled!
            documents << { "id" => "S#{documents.size + 1}", "url" => url, "title" => parsed.title,
              "body" => parsed.body_text.to_s.first(MAX_BODY_LENGTH), "fetched_at" => Time.current.iso8601,
              "truncated" => parsed.body_text.to_s.length > MAX_BODY_LENGTH, "candidate_role" => role }
          end
        rescue UrlNormalizer::InvalidUrlError
          attempts += 1
          @result.fetch("failures") << { "url" => candidate.url, "reason" => "unsafe_url" }
        rescue Fetchers::ChromiumFetcher::FetchError, Timeout::Error
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

    def queries!(value, min: 0)
      raise InvalidResponse unless value.is_a?(Array) && value.size.between?(min, 2)
      value.each { |query| text!(query, max: 300) }
    end

    def validate_plan!(plan)
      object!(plan, %w[scope news_queries evidence_queries])
      text!(plan.fetch("scope"), max: 2000)
      queries!(plan.fetch("news_queries"), min: 1)
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
        object!(item, %w[id kind reason quote])
        raise InvalidResponse unless DOCUMENT_KINDS.include?(item.fetch("kind"))
        text!(item.fetch("reason"), max: 2000)
        grounded_quote!(item, "quote")
      end
    end
  end
end
