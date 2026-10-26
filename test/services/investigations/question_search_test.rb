require "test_helper"

class Investigations::QuestionSearchTest < ActiveSupport::TestCase
  test "finds related reports for a natural question and ranks editorial quality before confidence" do
    mixed = report("Eleições brasileiras foram auditadas em 2022", quality: "mixed", confidence: 0.99)
    strong = report("Auditoria das eleições no Brasil em 2022", quality: "strong", confidence: 0.5)
    report("Eleições nos Estados Unidos em 2022", quality: "strong")
    report("Eleições no Brasil em 2018", quality: "strong")
    report("Inflação no Brasil em 2022", quality: "strong")

    result = search("as eleicoes br em 2022 foram honestas?")

    assert_equal [ strong.slug, mixed.slug ], result[:results].pluck(:slug)
    assert_equal %w[strong mixed], result[:results].pluck(:quality)
    assert_equal "local_archive", result[:source]
    assert_equal 0.5, result[:results].first[:confidence]
    assert_equal strong.normalized_url, result[:results].first[:source_url]
  end

  test "searches stored claims and conclusions without fabricating a new answer" do
    investigation = report("Relatório técnico", quality: "mixed")
    investigation.update!(llm_summary: { "overall_quality" => "mixed", "conclusion" => "A auditoria examinou equipamentos eletrônicos." })
    claim = Claim.create!(canonical_text: "Os equipamentos foram auditados.", canonical_fingerprint: SecureRandom.hex)
    investigation.claim_assessments.create!(claim:, verdict: :needs_more_evidence, reason_summary: "Documentação incompleta")

    result = search("equipamentos auditados")[:results].sole
    assert_equal investigation.slug, result[:slug]
    assert_equal "A auditoria examinou equipamentos eletrônicos.", result[:conclusion]
    assert_equal "needs_more_evidence", result[:claims].sole[:verdict]
    assert_equal "Documentação incompleta", result[:claims].sole[:reason]
  end

  test "never promotes unfinished or stale group evidence as a recommendation" do
    report("Vacinas infantis", status: :processing)
    report("Vacinas infantis", status: :failed)
    investigation = report("Vacinas infantis", quality: "strong")
    group = InvestigationGroup.create!(main_investigation: investigation, evidence_revision: 2)
    investigation.update!(investigation_group: group, group_membership_kind: :manual, evidence_revision_assessed: 1)

    assert_empty search("vacinas infantis")[:results]
  end

  test "keeps missing and insufficient quality explicit and last" do
    missing = report("Vacinas infantis", quality: nil)
    insufficient = report("Vacinas infantis", quality: "insufficient")
    weak = report("Vacinas infantis", quality: "weak")

    items = search("vacinas infantis")[:results]
    assert_equal weak.slug, items.first[:slug]
    assert_equal [ insufficient.slug, missing.slug ].sort, items.drop(1).pluck(:slug).sort
    assert_nil items.find { |item| item[:slug] == missing.slug }[:quality]
  end

  test "failed model calls remain visible as degraded reports without hiding their limitations" do
    investigation = report("Vacinas infantis", quality: "mixed")
    investigation.update!(llm_summary: { "overall_quality" => "mixed", "weaknesses" => [ "Faltam documentos" ] })
    LlmInteraction.create!(investigation:, model_id: "test-model", prompt_text: "test", status: :failed)

    item = search("vacinas infantis")[:results].sole
    assert item[:degraded]
    assert_equal [ "Faltam documentos" ], item[:weaknesses]
  end

  test "literal wildcard input and unrelated questions return no matches and perform no submissions" do
    report("Eleições no Brasil", quality: "strong")
    assert_no_difference [ "Investigation.count", "Article.count", "LlmInteraction.count" ] do
      assert_no_enqueued_jobs do
        assert_empty search("astronomia galaxias")[:results]
        assert_empty search("%_' OR 1=1 --")[:results]
      end
    end
  end

  test "rejects malformed empty oversized and question-only input" do
    [ nil, [], {}, " ", "a" * 501, "isso é verdade?" ].each do |question|
      assert_raises(Investigations::QuestionSearch::InvalidQuestion) { search(question) }
    end
  end

  test "quality sorting happens before the result limit and ties are deterministic" do
    11.times { report("Vacinas infantis", quality: "weak") }
    best = report("Vacinas infantis", quality: "strong")
    first = search("vacinas infantis")[:results]
    assert_equal 10, first.size
    assert_equal best.slug, first.first[:slug]
    assert_equal first.pluck(:slug), search("vacinas infantis")[:results].pluck(:slug)
  end

  private

  def search(question)
    Investigations::QuestionSearch.call(question:)
  end

  def report(title, quality: "mixed", confidence: 0.7, status: :completed)
    url = "https://example.com/question-#{SecureRandom.hex(8)}"
    article = Article.create!(url:, normalized_url: url, host: "example.com", title:, fetch_status: :fetched)
    Investigation.create!(submitted_url: url, normalized_url: url, root_article: article, status:,
      overall_confidence_score: confidence, llm_summary: quality ? { "overall_quality" => quality } : nil)
  end
end
