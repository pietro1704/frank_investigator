class QuestionsController < ApplicationController
  def show
    @question = params[:question].is_a?(String) ? params[:question] : ""
    @result = Investigations::QuestionSearch.call(question: params[:question])
    respond_to do |format|
      format.html
      format.json { render json: @result }
    end
  rescue Investigations::QuestionSearch::InvalidQuestion
    @error = t("questions.show.invalid", max: Investigations::QuestionSearch::MAX_LENGTH)
    respond_to do |format|
      format.html { render :show, status: :unprocessable_entity }
      format.json { render json: { error: "invalid_question", message: @error }, status: :unprocessable_entity }
    end
  end
end
