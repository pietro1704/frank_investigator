module Investigations
  # Sampling diversity is independent of truth and article quality.
  class TopicSourceSelection
    def self.call(documents:, relevant_ids:, editorial_counts:)
      new(documents:, relevant_ids:, editorial_counts:).call
    end

    def initialize(documents:, relevant_ids:, editorial_counts:)
      @documents, @relevant_ids, @counts = documents, relevant_ids, editorial_counts
    end

    def call
      excluded = []
      independent = []
      @documents.each do |document|
        next unless document["kind"] == "news_article" && @relevant_ids.include?(document["id"])
        if independent.any? { |other| same_origin?(document, other) }
          excluded << { "id" => document.fetch("id"), "reason" => "same_origin" }
        else
          independent << document
        end
      end
      requested = @counts.values.sum
      target = requested.positive? ? requested : TopicDiscovery::MAX_NEWS_PAGES
      selected = []
      missing = @counts.dup
      @counts.each do |side, count|
        matches = independent.select { |item| documented?(item, side) }.first(count)
        selected.concat(matches)
        missing[side] = count - matches.size
      end
      uncertain = independent.reject { |item| item["editorial_confidence"] == "documented" && TopicPlan::SIDES.include?(item["editorial_position"]) }
      extras = requested.positive? ? uncertain : independent
      selected.concat(extras.reject { |item| selected.include?(item) }.first([ target - selected.size, 0 ].max))
      { "news_ids" => selected.pluck("id"), "requested" => target, "missing" => missing,
        "uncertain_ids" => uncertain.pluck("id"), "excluded" => excluded,
        "coverage_complete" => selected.size >= target && missing.values.sum.zero? }
    end

    private

    def documented?(item, side)
      item["editorial_position"] == side && item["editorial_confidence"] == "documented"
    end

    def origin(document)
      host = URI.parse(document.fetch("url")).host.to_s.downcase
      MediaOwnershipGroup.group_for_host(host)&.name || Sources::ProfileRegistry.match(host)&.independence_group || host
    end

    def same_origin?(left, right)
      return true if origin(left) == origin(right)
      a = Analyzers::TextAnalysis.tokenize(left.fetch("body"))
      b = Analyzers::TextAnalysis.tokenize(right.fetch("body"))
      return false if a.empty? || b.empty?
      Analyzers::TextAnalysis.jaccard_similarity(a, b) >= Analyzers::IndependenceAnalyzer::SYNDICATION_SIMILARITY_THRESHOLD
    end
  end
end
