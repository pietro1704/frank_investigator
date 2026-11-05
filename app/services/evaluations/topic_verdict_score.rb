module Evaluations
  # Independent, deliberately small rubric over annotated source relationships.
  # Literal quotation checks do not claim universal semantic entailment.
  class TopicVerdictScore
    DEFINITIVE = %w[supported disputed mixed].freeze
    CERTAINTY = /definitely (?:true|false)|beyond (?:any|all) doubt|sem (?:qualquer )?dúvida|com certeza absoluta|comprovadamente (?:verdadeir[oa]|fals[oa])/i

    def self.call(entry:, report:)
      expected = entry.fetch("expected")
      documents = entry.fetch("discovery").fetch("documents").index_by { |item| item["id"] }
      articles = Array(report["articles"])
      failures = []
      failures << "case_identity" unless report["question"] == entry.fetch("question")
      failures << "article_identity" unless articles.pluck("source_id").sort == entry.fetch("news_ids").sort
      verdict_ok = articles.any? && articles.all? { |item| expected.fetch("verdicts").include?(item["verdict"]) }
      failures << "verdict" unless verdict_ok
      citations_ok = articles.all? do |article|
        Array(article["evidence"]).all? do |cite|
          source = documents[cite["source_id"]]
          allowed = expected.fetch("relationships").fetch(cite["source_id"], [])
          quote = cite["quote"]
          source && quote.is_a?(String) && quote.strip.length >= 20 && source["body"].squish.include?(quote.squish) && allowed.include?(cite["relationship"])
        end
      end
      articles.each do |article|
        next unless DEFINITIVE.include?(article["verdict"])
        required = expected.fetch("required_decisive_sources")
        citations_ok &&= required.any? && Array(article["evidence"]).any? do |cite|
          required.include?(cite["source_id"]) && documents.dig(cite["source_id"], "kind") == "producer_publication" &&
            %w[supports disputes].include?(cite["relationship"]) && cite["primary_reason"].to_s.strip.length >= 20
        end
      end
      failures << "citation_support" unless citations_ok
      uncertainty_expected = (expected.fetch("verdicts") & DEFINITIVE).empty?
      overconfident = uncertainty_expected && articles.any? do |article|
        DEFINITIVE.include?(article["verdict"]) || article["conclusion"].to_s.match?(CERTAINTY)
      end
      failures << "overconfidence" if overconfident
      { "failures" => failures, "verdicts" => articles.pluck("verdict"),
        "checks" => { "verdict" => verdict_ok, "citation_support" => !!citations_ok, "overconfidence" => !!overconfident },
        "conclusions" => articles.pluck("conclusion"), "citations" => articles.flat_map { |item| Array(item["evidence"]).map { |cite|
          cite.slice("source_id", "quote", "relationship", "primary_reason").merge("url" => documents.dig(cite["source_id"], "url"))
        } } }
    end
  end
end
