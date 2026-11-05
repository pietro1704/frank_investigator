class ReportExportsController < ApplicationController
  MAX_DOCUMENT_BYTES = 5.megabytes
  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }
  rescue_from ReportExports::Pdf::Unavailable, with: :unavailable

  def article
    export(Investigation.find_by!(slug: params[:id]))
  end

  def topic
    export(TopicInvestigation.find_by!(slug: params[:id]))
  end

  private

  def export(record)
    response.headers["Cache-Control"] = "no-store"
    return head :not_acceptable unless request.format.symbol.in?(%i[pdf epub])
    return render_error(:conflict, "unfinished") unless record.completed?
    report_url = record.is_a?(TopicInvestigation) ? topic_investigation_url(record) : investigation_url(record)
    document = ReportExports::Document.new(record:, report_url:)
    return render_error(:content_too_large, "too_large") if ReportExports::Html.new(document).book.bytesize > MAX_DOCUMENT_BYTES
    data = request.format.pdf? ? ReportExports::Pdf.call(document) : ReportExports::Epub.call(document)
    send_data data, filename: "frank-#{record.model_name.singular}-#{record.slug}.#{request.format.symbol}",
      type: request.format.to_s, disposition: "attachment"
  end

  def unavailable
    response.headers["Retry-After"] = "5"
    render_error(:service_unavailable, "unavailable")
  end

  def render_error(status, key)
    render plain: I18n.t("report_exports.errors.#{key}"), status:
  end
end
