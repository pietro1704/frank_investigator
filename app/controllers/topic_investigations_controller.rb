class TopicInvestigationsController < ApplicationController
  before_action :authenticate_submitter!, except: :show

  def new
    @question = params[:question].is_a?(String) ? params[:question] : ""
  end

  def create
    @topic = Investigations::SubmitTopic.call(question: params[:question])
    respond_to do |format|
      format.html { redirect_to topic_investigation_path(@topic), status: :see_other }
      format.json { render json: representation, status: :accepted, location: topic_investigation_path(@topic) }
    end
  rescue Investigations::TopicDiscovery::InvalidQuestion
    @question = params[:question].is_a?(String) ? params[:question] : ""
    @error = t("topics.invalid", max: Investigations::TopicDiscovery::MAX_QUESTION_LENGTH)
    respond_to do |format|
      format.html { render :new, status: :unprocessable_entity }
      format.json { render json: { error: "invalid_question", message: @error }, status: :unprocessable_entity }
    end
  end

  def show
    @topic = TopicInvestigation.find_by!(slug: params[:id])
    response.headers["Cache-Control"] = "no-store"
    response.headers["Retry-After"] = "5" if active?
    respond_to do |format|
      format.html
      format.json { render json: representation, status: active? ? :accepted : :ok }
    end
  end

  def deepen_article
    @topic = TopicInvestigation.find_by!(slug: params[:id])
    result = Investigations::DeepenTopicArticle.call(topic: @topic, generation: params[:generation], source_id: params[:source_id])
    respond_to do |format|
      format.html { redirect_to investigation_path(result.investigation), status: :see_other }
      format.json { render json: { slug: result.investigation.slug, report_url: investigation_path(result.investigation),
        status: result.investigation.status, delivery_deferred: result.delivery_deferred }, status: :accepted }
    end
  rescue Investigations::DeepenTopicArticle::Conflict
    conflict
  rescue Investigations::UrlNormalizer::InvalidUrlError, Investigations::UrlClassifier::RejectedUrlError
    article_submission_error(:unprocessable_entity)
  rescue Investigations::DeepenTopicArticle::Unavailable
    article_submission_error(:service_unavailable)
  end

  def cancel
    @topic = TopicInvestigation.find_by!(slug: params[:id])
    return conflict unless @topic.cancel!
    redirect_to topic_investigation_path(@topic), status: :see_other
  end

  def restart
    @topic = TopicInvestigation.find_by!(slug: params[:id])
    Investigations::SubmitTopic.restart(topic: @topic, fresh: params[:fresh] == "1")
    redirect_to topic_investigation_path(@topic), status: :see_other
  rescue Investigations::SubmitTopic::Conflict
    conflict
  end

  private

  def active?
    TopicInvestigation::ACTIVE_STATUSES.include?(@topic.status)
  end

  def representation
    coverage = TopicCoveragePresenter.call(@topic)
    { slug: @topic.slug, question: @topic.question, status: @topic.status, stage: @topic.stage,
      ready: @topic.completed? && coverage.fetch("complete"), terminal: !active?,
      report_available: @topic.completed? && @topic.report.present?, coverage:,
      synthesis_progress: @topic.synthesis_progress, resumable: @topic.resumable?,
      retrieval: @topic.discovery.slice("budget", "additional_evidence_rounds", "retrieval_limited"),
      plan: @topic.discovery["plan"], error_code: @topic.error_code,
      started_at: @topic.started_at, finished_at: @topic.finished_at,
      comparison: TopicComparisonPresenter.call(@topic), answer: TopicAnswerPresenter.call(@topic), report: public_report,
      sources: Array(@topic.discovery["documents"]).map { |item| item.slice("id", "title", "url", "kind", "fetched_at", "truncated") },
      failures: Array(@topic.discovery["failures"]),
      editorial_profiles: @topic.discovery.fetch("editorial_profiles", {}).values }
  end

  def public_report
    report = @topic.report.except("model_result").deep_dup
    if report.key?("full_analyses")
      report["full_analyses"] = Array(report["full_analyses"]).map { |item| item.except("evidence_documents") }
    end
    report
  end

  def article_submission_error(status)
    @notice = t("topics.deepen_unavailable")
    respond_to do |format|
      format.html { render :show, status: }
      format.json { render json: { error: "article_submission_unavailable", message: @notice }, status: }
    end
  end

  def conflict
    @topic.reload
    @notice = t("topics.conflict")
    respond_to do |format|
      format.html { render :show, status: :conflict }
      format.json { render json: { error: "state_conflict", message: @notice }, status: :conflict }
    end
  end

  def authenticate_submitter!
    secret = ENV["FRANK_AUTH_SECRET"]
    return if secret.blank?
    authenticate_or_request_with_http_basic("Frank Investigator") do |_user, password|
      ActiveSupport::SecurityUtils.secure_compare(password, secret)
    end
  end
end
