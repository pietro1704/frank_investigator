module Investigations
  class TopicAnalysisSnapshot
    def self.call(link)
      investigation = link.investigation
      base = { "source_id" => link.source_id, "url" => link.source_url, "slug" => investigation&.slug,
        "checked_at" => Time.current.iso8601 }
      return base.merge("status" => "failed", "error_code" => "missing_analysis") unless investigation
      return base.merge("status" => "failed", "error_code" => "source_identity_mismatch") unless investigation.normalized_url == link.source_url
      return base.merge("status" => "failed", "error_code" => "analysis_failed") if investigation.failed?
      return base.merge("status" => "pending") unless ReadinessPresenter.call(investigation).fetch(:ready)
      ttl = Rails.configuration.x.frank_investigator.article_freshness_ttl.seconds
      if !investigation.root_article&.fresh? || !investigation.analysis_completed_at || investigation.analysis_completed_at <= ttl.ago ||
          investigation.claim_assessments.where("stale_at IS NOT NULL AND stale_at <= ?", Time.current).exists?
        return base.merge("status" => "stale", "error_code" => "stale_analysis")
      end
      claims = investigation.claim_assessments.includes(:claim).order(:id).limit(21).to_a
      base.merge("status" => "ready", "analyzed_at" => investigation.analysis_completed_at.iso8601,
        "conclusion" => investigation.llm_summary&.dig("conclusion").presence || investigation.summary,
        "editorial_summary" => investigation.llm_summary || {}, "evidence_documents" => evidence_documents(investigation), "claims_truncated" => claims.size > 20,
        "claims" => claims.first(20).map { |item| { "text" => item.claim.canonical_text, "verdict" => item.verdict,
          "reason" => item.reason_summary.to_s.first(1000), "checkability" => item.checkability_status } })
    end

    def self.evidence_documents(investigation)
      Article.joins(evidence_items: :claim_assessment).where(claim_assessments: { investigation_id: investigation.id }, fetch_status: "fetched")
        .distinct.order(:id).limit(4).filter_map do |article|
        next if article.body_text.blank?
        { "id" => "A#{article.id}", "url" => article.normalized_url, "title" => article.title.to_s,
          "body" => article.body_text.first(TopicDiscovery::MAX_BODY_LENGTH), "truncated" => article.body_text.length > TopicDiscovery::MAX_BODY_LENGTH,
          "kind" => article.primary_source? ? "producer_publication" : "news_article", "fetched_at" => article.fetched_at&.iso8601 }
      end
    end
    private_class_method :evidence_documents
  end
end
