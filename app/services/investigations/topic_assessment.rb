module Investigations
  # A brief assessment of the central statement in each discovered news article.
  # Quotes are grounded locally; producer status alone never establishes truth.
  class TopicAssessment
    class InvalidResponse < StandardError; end
    VERDICTS = %w[supported disputed mixed needs_more_evidence not_checkable].freeze
    QUALITIES = %w[strong mixed weak insufficient].freeze

    def self.call(discovery:, **options)
      new(discovery:, **options).call
    end

    def initialize(discovery:, model: ResearchModel.new, cancelled: -> { false })
      @discovery, @model, @cancelled = discovery.deep_dup, model, cancelled
    end

    def call
      validate_input!
      check_cancelled!
      raw = @model.assess(discovery: @discovery.deep_dup)
      check_cancelled!
      object!(raw, %w[question conclusion limitations articles])
      raise InvalidResponse unless raw.fetch("question") == @discovery.fetch("question")
      text!(raw.fetch("conclusion"), max: 6000)
      strings!(raw.fetch("limitations"))
      articles = raw.fetch("articles")
      raise InvalidResponse unless articles.is_a?(Array) && articles.all? { |item| item.is_a?(Hash) && item["source_id"].is_a?(String) }
      raise InvalidResponse unless articles.pluck("source_id").sort == @discovery.fetch("news_ids").sort

      adjusted = false
      normalized = articles.map do |article|
        validate_article!(article)
        item = article.deep_dup
        verdict = grounded_verdict(item)
        if verdict != item.fetch("verdict")
          adjusted = true
          item["verdict"] = verdict
          key = verdict == "mixed" ? "conflict" : (verdict == "not_checkable" ? "opinion" : "insufficient")
          explanation = I18n.t("topic_assessment.guards.#{key}")
          item["conclusion"] = explanation
          item["weaknesses"].unshift(explanation)
          item["overall_quality"] = verdict == "mixed" ? (item["overall_quality"] == "strong" ? "mixed" : item["overall_quality"]) : "insufficient"
        end
        item["evidence_ids"] = item.fetch("evidence").pluck("source_id").uniq
        item
      end
      limitations = raw.fetch("limitations").dup
      limitations << I18n.t("topic_assessment.unreadable") if @discovery.fetch("failures", []).any?
      limitations << I18n.t("topic_assessment.truncated") if @documents.values.any? { |item| item["truncated"] }
      check_cancelled!
      { "question" => @discovery.fetch("question"), "scope" => @discovery.fetch("scope"),
        "conclusion" => adjusted ? I18n.t("topic_assessment.adjusted") : raw.fetch("conclusion"),
        "limitations" => limitations.uniq, "articles" => normalized,
        "assessed_at" => Time.current.iso8601, "model_result" => raw }
    end

    private

    def validate_input!
      raise InvalidResponse unless @discovery.is_a?(Hash) && @discovery["status"] == "discovered"
      raise InvalidResponse unless @discovery["question"].is_a?(String) && @discovery["scope"].is_a?(String)
      docs = @discovery["documents"]
      raise InvalidResponse unless docs.is_a?(Array) && docs.size.between?(1, 10) && docs.all? { |item| item.is_a?(Hash) && item["id"].is_a?(String) && item["body"].is_a?(String) && item["title"].is_a?(String) }
      raise InvalidResponse unless docs.pluck("id").uniq.size == docs.size
      @documents = docs.index_by { |item| item.fetch("id") }
      ids = @discovery["news_ids"]
      raise InvalidResponse unless ids.is_a?(Array) && ids.any? && ids.uniq.size == ids.size
      raise InvalidResponse unless ids.all? { |id| @documents[id]&.fetch("kind", nil) == "news_article" }
    end

    def object!(value, keys)
      raise InvalidResponse unless value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def text!(value, max:, min: 1)
      raise InvalidResponse unless value.is_a?(String) && value.strip.length.between?(min, max)
    end

    def strings!(value)
      raise InvalidResponse unless value.is_a?(Array) && value.size <= 12
      value.each { |item| text!(item, max: 2000) }
    end

    def validate_article!(article)
      object!(article, %w[source_id verdict overall_quality article_quote conclusion strengths weaknesses evidence])
      raise InvalidResponse unless VERDICTS.include?(article.fetch("verdict")) && QUALITIES.include?(article.fetch("overall_quality"))
      text!(article.fetch("conclusion"), max: 5000)
      strings!(article.fetch("strengths"))
      strings!(article.fetch("weaknesses"))
      source = @documents.fetch(article.fetch("source_id"))
      text!(article.fetch("article_quote"), max: 2000, min: 15)
      quoted = article.fetch("article_quote").squish
      raise InvalidResponse unless source.fetch("body").squish.include?(quoted) || source.fetch("title").squish.include?(quoted)
      evidence = article.fetch("evidence")
      raise InvalidResponse unless evidence.is_a?(Array) && evidence.size <= 8
      evidence.each do |item|
        object!(item, %w[source_id quote relationship primary_reason])
        other = @documents[item.fetch("source_id")]
        raise InvalidResponse unless other && other.fetch("kind") != "index_or_other"
        raise InvalidResponse unless %w[supports disputes context].include?(item.fetch("relationship"))
        text!(item.fetch("quote"), max: 2000, min: 20)
        text!(item.fetch("primary_reason"), max: 2000, min: 0)
        raise InvalidResponse unless other.fetch("body").squish.include?(item.fetch("quote").squish)
      end
    end

    def grounded_verdict(article)
      source = @documents.fetch(article.fetch("source_id"))
      return "not_checkable" if [ article.fetch("article_quote"), source.fetch("title") ].any? { |text| Analyzers::CheckabilityClassifier.opinion_like?(text) }
      primary = article.fetch("evidence").select do |item|
        item.fetch("source_id") != article.fetch("source_id") &&
          @documents.fetch(item.fetch("source_id")).fetch("kind") == "producer_publication" && item.fetch("primary_reason").strip.length >= 20
      end
      supports = primary.any? { |item| item.fetch("relationship") == "supports" }
      disputes = primary.any? { |item| item.fetch("relationship") == "disputes" }
      case article.fetch("verdict")
      when "supported"
        disputes ? "mixed" : (supports ? "supported" : "needs_more_evidence")
      when "disputed"
        supports ? "mixed" : (disputes ? "disputed" : "needs_more_evidence")
      when "mixed"
        supports || disputes ? "mixed" : "needs_more_evidence"
      else
        article.fetch("verdict")
      end
    end

    def check_cancelled!
      raise TopicDiscovery::Cancelled if @cancelled.call
    end
  end
end
