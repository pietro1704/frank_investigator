# Shared presentation contract; processing completion is independent of factual certainty.
class TopicCoveragePresenter
  def self.call(topic)
    new(topic).call
  end

  def initialize(topic)
    @topic = topic
  end

  def call
    discovery = @topic.discovery
    documents = Array(discovery["documents"]).index_by { |item| item["id"] }
    selected = Array(discovery["news_ids"]).uniq.filter_map { |id| documents[id] }
    requirements = discovery.dig("plan", "requirements") || {}
    counts = requirements.fetch("editorial_counts", {})
    requested = requirements.fetch("news_count", 0).to_i
    requested = counts.values.sum if requested.zero?
    assessed_ids = @topic.completed? ? Array(@topic.report["articles"]).pluck("source_id") : []
    links = @topic.topic_analysis_links.for_run(@topic.run_token).includes(:investigation).index_by(&:source_id)
    sources = selected.map do |document|
      link = links[document["id"]]
      valid = link && link.source_url == document["url"]
      status = if @topic.analysis_mode_brief?
        assessed_ids.include?(document["id"]) ? "assessed" : "pending"
      elsif !@topic.full_analysis_required?
        "not_requested"
      else
        valid ? link.status : "pending"
      end
      { "source_id" => document["id"], "title" => document["title"], "url" => document["url"],
        "editorial_position" => document.fetch("editorial_position", "unknown"),
        "editorial_evidence" => editorial_evidence(document),
        "status" => status, "analysis_slug" => (link.investigation&.slug if valid),
        "error_code" => (link.error_code if valid && @topic.full_analysis_required?) }
    end
    ready_ids = sources.select { |item| item["status"].in?(%w[ready assessed]) }.pluck("source_id")
    quotas = counts.map do |side, count|
      members = selected.select { |item| item["editorial_position"] == side && item["editorial_confidence"] == "documented" }
      analyzed = members.count { |item| ready_ids.include?(item["id"]) }
      [ side, { "requested" => count, "selected" => members.size, "analyzed" => analyzed, "missing" => [ count - analyzed, 0 ].max } ]
    end.to_h
    target = if requested.positive?
      requested
    else
      @topic.analysis_mode_brief? ? selected.size : Investigations::TopicDiscovery::MAX_NEWS_PAGES
    end
    complete = if @topic.analysis_mode_brief?
      @topic.completed? && selected.any? && selected.size >= target && ready_ids.size == selected.size && quotas.values.all? { |quota| quota["missing"].zero? }
    elsif @topic.full_analysis_required?
      selected.size >= target && ready_ids.size == selected.size && quotas.values.all? { |quota| quota["missing"].zero? }
    else
      @topic.completed?
    end
    { "requested" => (requested if requested.positive?), "target" => target, "selected" => selected.size,
      "analyzed" => ready_ids.size, "pending" => sources.count { |item| item["status"] == "pending" },
      "failed" => sources.count { |item| item["status"].in?(%w[failed stale]) },
      "unread" => Array(discovery["failures"]).size, "editorial_quotas" => quotas,
      "complete" => complete, "sources" => sources }
  end
  private

  def editorial_evidence(document)
    evidence = Array(document.dig("editorial_profile", "evidence")).deep_dup
    if document["editorial_quote"].present?
      evidence << { "url" => document["url"], "quote" => document["editorial_quote"], "relation" => "article_self_description", "checked_at" => document["fetched_at"] }
    end
    evidence
  end
end
