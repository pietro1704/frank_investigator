module Investigations
  # Read-only retrieval of Frank's stored reports. It neither answers the question
  # nor interprets agreement with the question as a signal of editorial quality.
  class QuestionSearch
    class InvalidQuestion < ArgumentError; end

    MAX_LENGTH = 500
    LIMIT = 10
    QUALITY_ORDER = { "strong" => 0, "mixed" => 1, "weak" => 2, "insufficient" => 3 }.freeze
    STOP_WORDS = %w[
      a as o os um uma uns umas de da das do dos em no nos na nas por para com sem
      e ou que qual quais quem como quando onde porque sobre foi foram era eram
      e eh sao ser esta estao isso isto esse essa esses essas houve ha tem ter
      me mostre sugira noticia noticias reportagem reportagens frank verdade
      the a an of in on for to and or is are was were what which who how why
      did do does this that it be been about news
    ].freeze
    COUNTRY_TERMS = %w[brasil eua argentina portugal].freeze

    def self.call(question:)
      new(question:).call
    end

    def initialize(question:)
      raise InvalidQuestion unless question.is_a?(String) && question.strip.length.between?(1, MAX_LENGTH)

      @question = question.strip
      @terms = tokens(@question) - STOP_WORDS
      raise InvalidQuestion if @terms.empty?
    end

    def call
      matches = Investigation.completed.includes(:root_article, :claims, :pipeline_steps, :claim_assessments).filter_map do |investigation|
        next unless investigation.root_article
        next unless relevant?(investigation)
        next unless ReadinessPresenter.call(investigation)[:ready]

        item(investigation)
      end
      results = matches.sort_by do |item|
        [ QUALITY_ORDER.fetch(item[:quality], 4), -item[:matched_terms].size,
          -(item[:analyzed_at]&.to_f || 0), item[:slug] ]
      end.first(LIMIT)
      { question: @question, source: "local_archive", total: matches.size, results: }
    end

    private

    def tokens(text)
      normalized = I18n.transliterate(text.to_s).downcase.gsub(/\bestados unidos\b/, "eua")
      normalized.scan(/[a-z0-9]+/).map do |word|
        if word.match?(/\A(?:br|brazil|brasil|brasileir[ao]s?)\z/)
          "brasil"
        elsif word.length > 4 && word.end_with?("oes")
          word.sub(/oes\z/, "ao")
        elsif word.length > 4 && word.end_with?("s")
          word.delete_suffix("s")
        else
          word
        end
      end.uniq
    end

    def document(investigation)
      [ investigation.root_article.title, investigation.honest_headline,
        investigation.root_article.excerpt, investigation.summary,
        investigation.llm_summary&.dig("conclusion"),
        *investigation.claims.map(&:canonical_text) ].compact.join(" ")
    end

    def matched_terms(investigation)
      @terms & tokens(document(investigation))
    end

    def relevant?(investigation)
      matched = matched_terms(investigation)
      anchors = @terms.select { |term| COUNTRY_TERMS.include?(term) || term.match?(/\A\d+\z/) }
      topic_terms = @terms - anchors
      return false unless (anchors - matched).empty?
      return false if topic_terms.any? && (topic_terms & matched).empty?

      matched.size >= (@terms.size * 0.6).ceil
    end

    def item(investigation)
      quality = investigation.llm_summary&.dig("overall_quality")
      quality = nil unless QUALITY_ORDER.key?(quality)
      {
        slug: investigation.slug, title: investigation.root_article.title,
        honest_headline: investigation.honest_headline,
        source_url: investigation.normalized_url, outlet: investigation.root_article.host,
        report_path: Rails.application.routes.url_helpers.investigation_path(investigation),
        quality:, confidence: investigation.overall_confidence_score&.to_f,
        analyzed_at: investigation.analysis_completed_at || investigation.updated_at,
        conclusion: investigation.llm_summary&.dig("conclusion").presence || investigation.summary,
        weaknesses: Array(investigation.llm_summary&.dig("weaknesses")),
        matched_terms: matched_terms(investigation),
        degraded: investigation.pipeline_steps.any?(&:failed?) || LlmInteraction.where(investigation:, status: "failed").exists?,
        claims: investigation.claim_assessments.sort_by(&:id).map do |assessment|
          { text: assessment.claim.canonical_text, verdict: assessment.verdict,
            checkability_status: assessment.checkability_status, reason: assessment.reason_summary }
        end
      }
    end
  end
end
