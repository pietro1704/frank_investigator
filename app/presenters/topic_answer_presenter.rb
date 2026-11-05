# A read-only projection of guarded results, never a second model conclusion.
class TopicAnswerPresenter
  GROUPS = %w[known disputed missing].freeze

  def self.call(topic)
    return GROUPS.index_with { [] } unless topic.completed?
    new(discovery: topic.discovery, report: topic.report).call
  end

  def initialize(discovery:, report:)
    @report = report
    @documents = Investigations::TopicEvidenceCorpus.call(discovery, supplemental: true).index_by { |item| item["id"] }
  rescue Investigations::TopicAssessment::InvalidResponse, KeyError
    @documents = {}
  end

  def call
    groups = GROUPS.index_with { [] }
    sections = Array(@report["sections"])
    entries = sections.any? ? sections : Array(@report["articles"])
    entries.select { |item| item.is_a?(Hash) }.each do |item|
      citations = citations_for(item)
      decisive = citations.select { |cite| cite.delete("decisive") }
      supports = decisive.any? { |cite| cite["relationship"] == "supports" }
      disputes = decisive.any? { |cite| cite["relationship"] == "disputes" }
      verdict = item["verdict"]
      group = if verdict == "supported" && supports && !disputes
        "known"
      elsif (verdict == "disputed" && disputes) || (verdict == "mixed" && (supports || disputes))
        "disputed"
      else
        "missing"
      end
      unsupported = group == "missing" && %w[supported disputed mixed].include?(verdict)
      groups[group] << { "id" => item["question_id"] || item["source_id"],
        "claim" => item["question"] || item["article_quote"], "verdict" => unsupported ? "needs_more_evidence" : verdict,
        "conclusion" => unsupported ? I18n.t("topic_assessment.guards.insufficient") : item["conclusion"],
        "limitations" => Array(item["limitations"]), "citations" => citations }
    end
    groups
  end

  private

  def citations_for(item)
    Array(item["evidence"]).filter_map do |evidence|
      next unless evidence.is_a?(Hash)
      source = @documents[evidence["source_id"]]
      quote = evidence["quote"]
      next unless source && quote.is_a?(String) && quote.strip.length >= 20 && source["body"].squish.include?(quote.squish)
      next unless %w[supports disputes context].include?(evidence["relationship"])
      temporal_mismatch = !item.key?("question_id") && Investigations::TopicCitationScope.disjoint_years?(
        claim: [ item["article_quote"], @documents.dig(item["source_id"], "title") ].join(" "),
        reference: [ quote, source["title"] ].join(" "))
      scope_matches = !item.key?("question_id") || (evidence["scope_match"] == Investigations::TopicSynthesis::DIMENSIONS.index_with { true } &&
        evidence["scope_quote"].is_a?(String) && evidence["scope_quote"].strip.length >= 20 && source["body"].squish.include?(evidence["scope_quote"].squish))
      { "source_id" => source["id"], "title" => source["title"], "url" => source["url"],
        "quote" => quote, "relationship" => temporal_mismatch ? "context" : evidence["relationship"],
        "decisive" => source["kind"] == "producer_publication" && source["id"] != item["source_id"] &&
          evidence["primary_reason"].to_s.strip.length >= 20 && scope_matches && !temporal_mismatch }
    end
  end
end
