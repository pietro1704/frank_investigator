require "test_helper"
require "zip"
require "ferrum"

class ReportExportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @article = Article.create!(url: "https://news.example/export-story", normalized_url: "https://news.example/export-story",
      host: "news.example", title: "Acentuação: ciência & evidência", fetch_status: :fetched)
    @investigation = Investigation.create!(submitted_url: @article.url, normalized_url: @article.url, root_article: @article,
      status: :completed, llm_summary: { "overall_quality" => "mixed", "conclusion" => "A conclusão verificada contém ressalvas.",
      "strengths" => [ "Apresenta dados" ], "weaknesses" => [ "Falta contexto" ] })
    directory = Rails.root.join("test/fixtures/files/topic_assessment")
    @topic = TopicInvestigation.create!(question: "O desmatamento na Amazônia caiu em 2024?", status: :completed,
      analysis_mode: :brief, discovery: JSON.parse(File.read(directory.join("input.json"))),
      report: JSON.parse(File.read(directory.join("report.json"))), finished_at: Time.current)
  end

  test "both completed report pages offer real PDF and EPUB downloads without JavaScript" do
    [ [ investigation_path(@investigation), "investigations", @investigation.slug ],
      [ topic_investigation_path(@topic), "topic_investigations", @topic.slug ] ].each do |page, kind, slug|
      get page
      assert_response :success
      %w[pdf epub].each do |format|
        assert_select "a[href='/#{kind}/#{slug}/export.#{format}'][data-turbo='false']", count: 1
      end
    end
  end

  test "EPUB downloads preserve the right saved report and valid navigable package without writes or jobs" do
    [ [ "/investigations/#{@investigation.slug}/export.epub", @article.title ],
      [ "/topic_investigations/#{@topic.slug}/export.epub", @topic.question ] ].each do |path, title|
      assert_no_difference [ "Investigation.count", "TopicInvestigation.count", "Article.count", "LlmInteraction.count" ] do
        assert_no_enqueued_jobs { get path }
      end
      assert_response :success
      assert_equal "application/epub+zip", response.media_type
      assert_includes response.headers["Content-Disposition"], "attachment"
      entries = {}
      Zip::InputStream.open(StringIO.new(response.body.b)) do |zip|
        while (entry = zip.get_next_entry)
          entries[entry.name] = zip.read.force_encoding(Encoding::UTF_8)
        end
      end
      assert_equal "mimetype", entries.keys.first
      assert_equal "application/epub+zip", entries["mimetype"]
      assert_equal 0, response.body.b.unpack1("@28v"), "EPUB mimetype must have no local ZIP extra field"
      assert_equal 0, response.body.b.unpack1("@8v"), "EPUB mimetype must be stored, not compressed"
      package = Nokogiri::XML(entries.fetch("EPUB/package.opf")) { |config| config.strict.nonet }
      assert_equal title, package.at_xpath("//*[local-name()='title']").text
      assert_includes package.at_xpath("//*[local-name()='source']").text, path.delete_suffix("/export.epub")
      manifest = package.xpath("//*[local-name()='item']").map { |item| item["href"] }
      assert manifest.include?("nav.xhtml")
      manifest.each { |href| assert entries.key?("EPUB/#{href}"), "Missing EPUB resource #{href}" }
      entries.select { |name, _| name.end_with?(".xhtml", ".opf", ".xml") }.each_value do |xml|
        assert Nokogiri::XML(xml) { |config| config.strict.nonet }
      end
      assert_includes entries.fetch("EPUB/cover.xhtml"), ERB::Util.html_escape(title)
      assert_includes entries.fetch("EPUB/nav.xhtml"), 'epub:type="toc"'
    end
  end

  test "PDF downloads are actual paginated documents for both report identities" do
    paths = [ "/investigations/#{@investigation.slug}/export.pdf", "/topic_investigations/#{@topic.slug}/export.pdf" ]
    (paths * 5).each do |path|
      diagnostics = []
      trace = TracePoint.new(:raise) do |event|
        error = event.raised_exception
        diagnostics << "#{error.class}: #{error.message}" if error.is_a?(Ferrum::Error) || error.is_a?(Timeout::Error)
        diagnostics << "Unavailable; renderer_owned=#{ReportExports::Pdf::LOCK.owned?}" if error.is_a?(ReportExports::Pdf::Unavailable)
      end
      trace.enable { assert_no_enqueued_jobs { get path } }
      assert_response :success, "[DEBUG-export-ci] #{diagnostics.last(3).join(' | ')}"
      assert_equal "application/pdf", response.media_type
      assert response.body.b.start_with?("%PDF-")
      assert response.body.b.rstrip.end_with?("%%EOF")
      assert response.body.b.scan(%r{/Type /Page\b}).size >= 3
      assert_includes response.headers["Content-Disposition"], ".pdf"
    end
  end

  test "unavailable PDF rendering returns a useful failure and releases capacity for another request" do
    original = Ferrum::Browser.method(:new)
    Ferrum::Browser.define_singleton_method(:new) { |**| raise Ferrum::BinaryNotFoundError }
    get "/investigations/#{@investigation.slug}/export.pdf"
    assert_response :service_unavailable
    assert_equal "5", response.headers["Retry-After"]
    assert_includes response.body, I18n.t("report_exports.errors.unavailable")
    refute ReportExports::Pdf::LOCK.locked?
    get "/investigations/#{@investigation.slug}/export.epub"
    assert_response :success
  ensure
    Ferrum::Browser.define_singleton_method(:new, original) if original
  end

  test "an occupied PDF renderer rejects repeated concurrent requests instead of starting another browser" do
    ReportExports::Pdf::LOCK.lock
    get "/topic_investigations/#{@topic.slug}/export.pdf"
    assert_response :service_unavailable
    assert ReportExports::Pdf::LOCK.locked?, "a competing request must not release another request's renderer"
  ensure
    ReportExports::Pdf::LOCK.unlock if ReportExports::Pdf::LOCK.owned?
  end

  test "oversized publications fail explicitly instead of silently truncating results" do
    @topic.update!(report: @topic.report.merge("limitations" => [ "long " * 1_100_000 ]))
    get "/topic_investigations/#{@topic.slug}/export.epub"
    assert_response :content_too_large
    assert_includes response.body, I18n.t("report_exports.errors.too_large")
  end

  test "export downloads retain the same public read access as report pages" do
    previous = ENV["FRANK_AUTH_SECRET"]
    ENV["FRANK_AUTH_SECRET"] = "private-submission-secret"
    get "/topic_investigations/#{@topic.slug}/export.epub"
    assert_response :success
    refute_includes response.body, "private-submission-secret"
  ensure
    ENV["FRANK_AUTH_SECRET"] = previous
  end

  test "repeated downloads are bounded without creating paid work" do
    previous_store, previous_enabled = Rack::Attack.cache.store, Rack::Attack.enabled
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.enabled = true
    6.times do
      get "/topic_investigations/#{@topic.slug}/export.epub"
      assert_response :success
    end
    assert_no_enqueued_jobs { get "/topic_investigations/#{@topic.slug}/export.pdf" }
    assert_response :too_many_requests
  ensure
    Rack::Attack.cache.store = previous_store
    Rack::Attack.enabled = previous_enabled
  end

  test "pending failed and cancelled work cannot be exported as a finished report" do
    [ [ :processing, :cancelled ], [ :failed, :failed ] ].each do |article_status, topic_status|
      @investigation.update!(status: article_status)
      @topic.update!(status: topic_status)
      [ "/investigations/#{@investigation.slug}/export.epub", "/topic_investigations/#{@topic.slug}/export.pdf" ].each do |path|
        assert_no_enqueued_jobs { get path }
        assert_response :conflict
        refute_includes response.media_type, "application/pdf"
      end
    end
  end

  test "missing identities and unsupported formats are rejected without generating a report" do
    get "/investigations/foreign/export.epub"
    assert_response :not_found
    get "/topic_investigations/foreign/export.pdf"
    assert_response :not_found
    assert_no_enqueued_jobs do
      get "/investigations/#{@investigation.slug}/export.zip"
    end
    assert_response :not_acceptable
  end
end
