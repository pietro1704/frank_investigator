module ReportExports
  # A read-only publication model. Only public report content enters the book;
  # templates, not the record's JSON keys, define the reading order.
  class Document
    Section = Data.define(:id, :title, :html)
    ANALYZERS = %w[headline_bait event_context coordinated_narrative emotional_manipulation
      source_misrepresentation temporal_manipulation statistical_deception selective_quotation
      authority_laundering rhetorical_analysis contextual_gaps].freeze
    attr_reader :record, :report_url, :title, :sections, :notice, :date

    def initialize(record:, report_url:)
      @record, @report_url, @sections = record, report_url, []
      @date = record.try(:finished_at) || record.try(:analysis_completed_at) || record.updated_at
      if record.is_a?(TopicInvestigation)
        build_topic
      else
        build_article
      end
    end

    def identifier
      "urn:frank-investigator:#{record.model_name.singular}:#{record.slug}"
    end

    private

    def add(title, html)
      clean = Html.clean(html, base_url: report_url)
      return if Nokogiri::HTML5.fragment(clean).text.strip.empty?
      @sections << Section.new(id: "section-#{@sections.size + 1}", title:, html: clean)
    end

    def render(partial, **locals)
      ApplicationController.render(partial:, locals:)
    end

    def build_topic
      @title = record.question
      coverage = TopicCoveragePresenter.call(record)
      @notice = I18n.t("report_exports.partial") unless coverage["complete"]
      add(I18n.t("report_exports.answer"), render("report_exports/topic_answer", answer: TopicAnswerPresenter.call(record)))
      rows = TopicComparisonPresenter.call(record)
      rows.each do |row|
        item = Array(record.report["articles"]).find { |article| article["source_id"] == row["source_id"] }
        add(row["title"], render("report_exports/topic_article", row:, item:))
      end
      add(I18n.t("topics.scope_and_limits"), render("report_exports/topic_limits", topic: record, coverage:))
    end

    def build_article
      @title = record.root_article&.title.presence || I18n.t("report_exports.article_title")
      @notice = I18n.t("report_exports.partial") unless Investigations::ReadinessPresenter.call(record)[:ready]
      add(I18n.t("report_exports.summary"), render("report_exports/article_summary", investigation: record))
      ANALYZERS.each do |name|
        heading = I18n.t("investigations.#{name}.heading")
        add(heading, render("investigations/#{name}", investigation: record))
      end
      assessments = record.claim_assessments.includes(:claim, evidence_items: :article).order(:id)
      add(I18n.t("investigations.show.what_we_checked"), render("report_exports/claims", assessments:))
      add(I18n.t("investigations.evidence_timeline.heading"), render("investigations/evidence_timeline", investigation: record))
      add(I18n.t("report_exports.sources"), render("report_exports/sources", investigation: record, assessments:))
    end
  end
end
