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

  def cancel
    @topic = TopicInvestigation.find_by!(slug: params[:id])
    return conflict unless @topic.cancel!
    redirect_to topic_investigation_path(@topic), status: :see_other
  end

  def restart
    @topic = TopicInvestigation.find_by!(slug: params[:id])
    Investigations::SubmitTopic.restart(topic: @topic)
    redirect_to topic_investigation_path(@topic), status: :see_other
  rescue Investigations::SubmitTopic::Conflict
    conflict
  end

  private

  def active?
    TopicInvestigation::ACTIVE_STATUSES.include?(@topic.status)
  end

  def representation
    { slug: @topic.slug, question: @topic.question, status: @topic.status, stage: @topic.stage,
      ready: @topic.completed?, error_code: @topic.error_code,
      started_at: @topic.started_at, finished_at: @topic.finished_at,
      report: @topic.report.except("model_result"),
      sources: Array(@topic.discovery["documents"]).map { |item| item.slice("id", "title", "url", "kind", "fetched_at", "truncated") },
      failures: Array(@topic.discovery["failures"]) }
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
