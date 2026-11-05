require "test_helper"

class ReportExports::DocumentTest < ActiveSupport::TestCase
  setup do
    root = Rails.root.join("test/fixtures/files/topic_assessment")
    question = "Acentos & <script>não executar</script>"
    @topic = TopicInvestigation.create!(question:, analysis_mode: :brief,
      status: :completed, finished_at: Time.current, discovery: JSON.parse(File.read(root.join("input.json"))).merge("question" => question),
      report: JSON.parse(File.read(root.join("report.json"))).merge("question" => question))
  end

  test "the question answer and article assessments retain literal evidence and omit private checkpoints" do
    @topic.update!(assessment_checkpoint: { "private_secret" => "PRIVATE-CHECKPOINT" },
      report: @topic.report.merge("model_result" => { "private" => "PRIVATE-MODEL-RESPONSE" }))
    doc = document
    html = ReportExports::Html.new(doc).book
    parsed = Nokogiri::XML(html) { |config| config.strict.nonet }
    assert_equal @topic.question, parsed.at_xpath("//*[local-name()='title']").text
    assert_includes html, @topic.report["articles"].first["evidence"].first["quote"]
    assert_includes html, @topic.report["articles"].first["weaknesses"].first
    assert_includes html, @topic.report["articles"].first["strengths"].first
    refute_includes html, "PRIVATE-CHECKPOINT"
    refute_includes html, "PRIVATE-MODEL-RESPONSE"
    refute parsed.at_xpath("//*[local-name()='script']")
    assert_equal I18n.t("report_exports.answer"), doc.sections.first.title
  end

  test "historic partial coverage is explicit and forged citations never become proof in either book format" do
    discovery = @topic.discovery.deep_dup
    discovery["plan"] = { "version" => 2, "requirements" => { "news_count" => 8 } }
    report = @topic.report.deep_dup
    report["articles"].first["evidence"].first["source_id"] = "UNREAD"
    @topic.update!(discovery:, report:)
    doc = document
    assert_equal I18n.t("report_exports.partial"), doc.notice
    known = Nokogiri::HTML5.fragment(doc.sections.first.html)
    refute_includes known.text, report["articles"].first["conclusion"]
    refute_includes ReportExports::Html.new(doc).book, "UNREAD"
  end

  test "publication HTML removes executable content and resolves safe links without fetching them" do
    html = '<details><summary>Evidence</summary><p>Résumé</p></details><script>alert(1)</script><img src="https://tracking.example/pixel" /><a href="file:///private/key">bad</a><a href="javascript:alert(1)">bad</a><a href="/investigations/report">report</a><span class="popover-content">hover only</span>'
    clean = ReportExports::Html.clean(html, base_url: "https://frank.example/topic_investigations/source")
    parsed = Nokogiri::XML.fragment(clean) { |config| config.strict.nonet }
    assert_equal 0, parsed.css("details, summary, script, img, [onclick]").size
    assert_equal "Evidence", parsed.at_css("h4").text
    rich = ReportExports::Html.clean("<details><summary><div><p>Rich title</p></div></summary><p>Body</p></details>", base_url: "https://frank.example/report")
    assert_empty Nokogiri::HTML5.fragment(rich).css("h4 div, h4 p")
    assert_includes rich, "Rich title"
    assert_equal [ "https://frank.example/investigations/report" ], parsed.css("a[href]").map { |node| node["href"] }
    refute_includes clean, "hover only"
    refute_includes clean, "tracking.example"
  end

  private

  def document
    ReportExports::Document.new(record: @topic, report_url: "https://frank.example/topic_investigations/#{@topic.slug}")
  end
end
