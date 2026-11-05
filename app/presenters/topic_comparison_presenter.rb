class TopicComparisonPresenter
  def self.call(topic)
    return [] unless topic.completed?
    discovery, report = topic.discovery, topic.report
    documents = Array(discovery["documents"]).index_by { |item| item["id"] }
    # Reuse citation validation and conservative verdict gates for legacy reports too.
    guarded = TopicAnswerPresenter.new(discovery:, report: report.except("sections")).call.values.flatten.index_by { |item| item["id"] }
    articles = Array(report["articles"]).select { |item| item.is_a?(Hash) && Array(discovery["news_ids"]).include?(item["source_id"]) }
    uses = articles.flat_map { |item| Array(guarded.dig(item["source_id"], "citations")).pluck("source_id").uniq }.tally
    articles.filter_map do |item|
      source = documents[item["source_id"]]
      point = guarded[item["source_id"]]
      next unless source && point
      citations = point.fetch("citations")
      challenged = %w[disputed mixed].include?(point["verdict"]) && citations.any? do |cite|
        evidence = Array(item["evidence"]).find { |entry| entry["source_id"] == cite["source_id"] && entry["quote"] == cite["quote"] }
        cite["relationship"] == "disputes" && documents.dig(cite["source_id"], "kind") == "producer_publication" &&
          cite["source_id"] != item["source_id"] && evidence["primary_reason"].to_s.strip.length >= 20
      end
      { "source_id" => item["source_id"], "title" => source["title"], "url" => source["url"],
        "claim" => point["claim"], "verdict" => point["verdict"], "conclusion" => point["conclusion"],
        "factual_challenge" => challenged, "citations" => citations,
        "overall_quality" => Investigations::TopicAssessment::QUALITIES.include?(item["overall_quality"]) ? item["overall_quality"] : "insufficient",
        "shared_source_ids" => citations.pluck("source_id").uniq.select { |id| uses.fetch(id, 0) > 1 },
        # These are editorial observations from the assessment, not new factual verdicts.
        # No evidence and no inference of intent may become an omission accusation.
        "editorial_observations" => citations.empty? ? [] : Array(item["weaknesses"]).select { |text|
          text.is_a?(String) && !text.match?(/deliberad|intencion|intentional|deliberate|purposefully|on purpose/i)
        } }
    end
  end
end
