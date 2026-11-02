module Investigations
  class TopicSynthesis
    DIMENSIONS = %w[population territory period metric].freeze
    InvalidResponse = TopicAssessment::InvalidResponse

    def self.call(discovery:, report:, **options)
      new(discovery:, report:, **options).call
    end

    def initialize(discovery:, report:, model: ResearchModel.new, cancelled: -> { false })
      @discovery, @report, @model, @cancelled = discovery.deep_dup, report.deep_dup, model, cancelled
    end

    def call
      check_cancelled!
      raise InvalidResponse unless @report["question"] == @discovery["question"] && @report["articles"].is_a?(Array) &&
        @report["articles"].all? { |item| item.is_a?(Hash) && item["source_id"].is_a?(String) } &&
        @report["articles"].pluck("source_id").sort == Array(@discovery["news_ids"]).sort
      questions = Array(@discovery.dig("plan", "requirements", "subquestions"))
      questions = [ @discovery.fetch("question") ] if questions.empty?
      raise InvalidResponse unless questions.size.between?(1, 6) && questions.all? { |question| question.is_a?(String) }
      questions = questions.each_with_index.map { |question, index| { "question_id" => "Q#{index + 1}", "question" => question } }
      documents = corpus
      @documents = documents.index_by { |item| item.fetch("id") }
      raw = @model.synthesize(input: { "question" => @discovery.fetch("question"), "scope" => @discovery.fetch("scope"),
        "subquestions" => questions, "documents" => documents, "article_assessments" => @report.fetch("articles"),
        "full_analyses" => @discovery.fetch("full_analyses", []).map { |item| item.except("evidence_documents") },
        "requirements" => @discovery.dig("plan", "requirements"), "coverage" => @discovery["selection"] })
      check_cancelled!
      object!(raw, %w[question sections limitations])
      raise InvalidResponse unless raw["question"] == @discovery.fetch("question")
      strings!(raw["limitations"])
      sections = raw["sections"]
      raise InvalidResponse unless sections.is_a?(Array) && sections.all? { |item| item.is_a?(Hash) && item["question_id"].is_a?(String) } &&
        sections.pluck("question_id").sort == questions.pluck("question_id").sort
      by_id = sections.index_by { |item| item.fetch("question_id") }
      guarded = questions.map do |question|
        section = by_id.fetch(question.fetch("question_id")).deep_dup
        validate_section!(section)
        section["question"] = question.fetch("question")
        verdict = guarded_verdict(section)
        if verdict != section["verdict"]
          key = if verdict == "mixed"
            "topic_assessment.guards.conflict"
          elsif verdict == "not_checkable"
            "topic_assessment.guards.opinion"
          elsif section.fetch("evidence").any? { |item| !item["scope_match"].values.all? }
            "topic_synthesis.scope_mismatch"
          else
            "topic_assessment.guards.insufficient"
          end
          section["conclusion"] = I18n.t(key)
          section["limitations"].unshift(section["conclusion"])
        end
        section["verdict"] = verdict
        section
      end
      limitations = (@report.fetch("limitations", []) + raw.fetch("limitations")).uniq
      limitations << I18n.t("topic_assessment.truncated") if documents.any? { |item| item["truncated"] }
      check_cancelled!
      @report.merge("sections" => guarded, "conclusion" => guarded.map { |item| "#{item['question']}\n#{item['conclusion']}" }.join("\n\n"),
        "limitations" => limitations.uniq, "synthesis_sources" => documents.map { |item| item.slice("id", "title", "url", "kind", "fetched_at", "truncated") },
        "model_result" => { "article_assessment" => @report["model_result"], "synthesis" => raw })
    end

    private

    def corpus
      documents = @discovery.fetch("documents").deep_dup
      extra = @discovery.fetch("full_analyses", []).select { |item| item["status"] == "ready" }.flat_map { |item| Array(item["evidence_documents"]) }
      seen = documents.pluck("url").to_set
      extra.first(48).each do |item|
        next if seen.include?(item["url"])
        break if documents.size >= 40
        documents << item.deep_dup
        seen.add(item.fetch("url"))
      end
      raise InvalidResponse unless documents.size.between?(1, 40) && documents.all? { |item| item.is_a?(Hash) && item["id"].is_a?(String) && item["body"].is_a?(String) } &&
        documents.pluck("id").uniq.size == documents.size
      documents
    end

    def object!(value, keys)
      raise InvalidResponse unless value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def text!(value, max: 2000, min: 1)
      raise InvalidResponse unless value.is_a?(String) && value.strip.length.between?(min, max)
    end

    def strings!(value)
      raise InvalidResponse unless value.is_a?(Array) && value.size <= 12
      value.each { |item| text!(item) }
    end

    def validate_section!(section)
      object!(section, %w[question_id verdict conclusion limitations evidence])
      raise InvalidResponse unless TopicAssessment::VERDICTS.include?(section["verdict"])
      text!(section["conclusion"])
      strings!(section["limitations"])
      evidence = section["evidence"]
      raise InvalidResponse unless evidence.is_a?(Array) && evidence.size <= 8
      evidence.each do |item|
        object!(item, %w[source_id quote scope_quote scope_reason primary_reason relationship scope_match])
        document = @documents[item["source_id"]]
        raise InvalidResponse unless document && document["kind"] != "index_or_other" && %w[supports disputes context].include?(item["relationship"])
        %w[quote scope_quote].each do |key|
          text!(item[key], min: 20)
          raise InvalidResponse unless document.fetch("body").squish.include?(item[key].squish)
        end
        text!(item["primary_reason"], min: 0)
        text!(item["scope_reason"])
        object!(item["scope_match"], DIMENSIONS)
        raise InvalidResponse unless item["scope_match"].values.all? { |value| [ true, false ].include?(value) }
      end
    end

    def guarded_verdict(section)
      return "not_checkable" if Analyzers::CheckabilityClassifier.opinion_like?(section["question"])
      primary = section["evidence"].select do |item|
        @documents.fetch(item["source_id"])["kind"] == "producer_publication" && item["primary_reason"].strip.length >= 20 && item["scope_match"].values.all?
      end
      supports = primary.any? { |item| item["relationship"] == "supports" }
      disputes = primary.any? { |item| item["relationship"] == "disputes" }
      case section["verdict"]
      when "supported" then disputes ? "mixed" : (supports ? "supported" : "needs_more_evidence")
      when "disputed" then supports ? "mixed" : (disputes ? "disputed" : "needs_more_evidence")
      when "mixed" then supports || disputes ? "mixed" : "needs_more_evidence"
      else section["verdict"]
      end
    end

    def check_cancelled!
      raise TopicDiscovery::Cancelled if @cancelled.call
    end
  end
end
