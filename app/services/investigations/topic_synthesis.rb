module Investigations
  class TopicSynthesis
    DIMENSIONS = %w[population territory period metric].freeze
    InvalidResponse = TopicAssessment::InvalidResponse

    def self.call(discovery:, report:, **options)
      new(discovery:, report:, **options).call
    end

    def initialize(discovery:, report:, model: ResearchModel.new, cancelled: -> { false }, checkpoint: {}, on_progress: ->(*) { })
      @discovery, @report, @model, @cancelled = discovery.deep_dup, report.deep_dup, model, cancelled
      @checkpoint, @on_progress = checkpoint.deep_dup, on_progress
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
      documents = TopicEvidenceCorpus.call(@discovery, supplemental: true)
      @documents = documents.index_by { |item| item.fetch("id") }
      context = { "question" => @discovery.fetch("question"), "scope" => @discovery.fetch("scope"),
        "documents" => documents, "article_assessments" => @report.fetch("articles").map { |item|
          item.slice("source_id", "verdict", "overall_quality").merge("conclusion" => item["conclusion"].to_s.first(1200))
        },
        "full_analyses" => @discovery.fetch("full_analyses", []).map { |item| item.slice("source_id", "status", "slug", "conclusion") },
        "requirements" => @discovery.dig("plan", "requirements"), "coverage" => @discovery["selection"] }
      fingerprint = TopicResearchFingerprint.call(context.merge("subquestions" => questions, "assessment_provenance" => @report["articles"]))
      unless @checkpoint["version"] == 1 && @checkpoint["fingerprint"] == fingerprint && @checkpoint["sections"].is_a?(Hash)
        @checkpoint = { "version" => 1, "fingerprint" => fingerprint, "sections" => {} }
      end
      @checkpoint["sections"].slice!(*questions.pluck("question_id"))
      entries = questions.map do |question|
        check_cancelled!
        saved = @checkpoint["sections"][question["question_id"]]
        if saved
          validate_section!(saved.fetch("section"))
          raise InvalidResponse unless saved.dig("section", "question_id") == question["question_id"]
          strings!(saved.fetch("limitations"))
        else
          publish_progress!
          saved = generate_section(context, question)
          @checkpoint["sections"][question["question_id"]] = saved
          publish_progress!
        end
        saved
      end
      guarded = entries.zip(questions).map do |entry, question|
        section = entry.fetch("section").deep_dup
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
      limitations = (@report.fetch("limitations", []) + entries.flat_map { |entry| entry.fetch("limitations") }).uniq
      limitations << I18n.t("topic_assessment.truncated") if documents.any? { |item| item["truncated"] }
      check_cancelled!
      @report.merge("sections" => guarded, "conclusion" => guarded.map { |item| "#{item['question']}\n#{item['conclusion']}" }.join("\n\n"),
        "limitations" => limitations.uniq, "synthesis_sources" => documents.map { |item| item.slice("id", "title", "url", "kind", "fetched_at", "truncated") },
        "model_result" => { "article_assessment" => @report["model_result"], "synthesis" => entries.map { |entry| entry.fetch("section") } })
    end

    private

    def generate_section(context, question)
      input = context.merge("subquestions" => [ question ])
      2.times do |attempt|
        check_cancelled!
        publish_progress!
        raw = @model.synthesize(input: input.deep_dup)
        check_cancelled!
        begin
          object!(raw, %w[question sections limitations])
          raise InvalidResponse unless raw["question"] == @discovery["question"]
          strings!(raw["limitations"])
          sections = raw["sections"]
          raise InvalidResponse unless sections.is_a?(Array) && sections.size == 1 && sections.first.is_a?(Hash) && sections.first["question_id"] == question["question_id"]
          validate_section!(sections.first)
          return { "section" => sections.first, "limitations" => raw["limitations"] }
        rescue InvalidResponse => error
          raise if attempt == 1
          input["validation_feedback"] = "Validation error: #{error.message}. The previous response failed source, literal-quotation, length or question identity validation. Return only the requested question_id. Cite only the supplied document IDs, copy contiguous literal passages, and use no evidence when none applies."
        end
      end
    end

    def publish_progress!
      check_cancelled!
      @on_progress.call(@checkpoint.deep_dup)
      check_cancelled!
    end

    def object!(value, keys)
      raise InvalidResponse unless value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def text!(value, max: 2000, min: 1)
      raise InvalidResponse, "text_length_expected_#{min}_to_#{max}" unless value.is_a?(String) && value.strip.length.between?(min, max)
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
