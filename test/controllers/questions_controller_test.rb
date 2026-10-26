require "test_helper"

class QuestionsControllerTest < ActionDispatch::IntegrationTest
  test "home offers a separate question form without requiring an article URL" do
    get root_path
    assert_response :success
    assert_select "form[action='/questions'][method='get'] input[name='question']"
  end

  test "html and json return the same stored recommendations with report and original links" do
    article = Article.create!(url: "https://example.com/vaccines", normalized_url: "https://example.com/vaccines", host: "example.com", title: "Vacinas infantis")
    investigation = Investigation.create!(submitted_url: article.url, normalized_url: article.url, root_article: article,
      status: :completed, llm_summary: { "overall_quality" => "strong", "conclusion" => "Conclusão armazenada" })

    assert_no_difference "Investigation.count" do
      assert_no_enqueued_jobs do
        get "/questions", params: { question: "vacinas infantis" }
      end
    end
    assert_response :success
    assert_select "a[href=?]", investigation_path(investigation)
    assert_select "a[href=?]", article.url
    assert_includes response.body, "Conclusão armazenada"

    get "/questions.json", params: { question: "vacinas infantis" }
    assert_response :success
    assert_equal investigation.slug, response.parsed_body["results"].sole["slug"]
  end

  test "empty results explain the archive boundary" do
    get "/questions", params: { question: "astronomia galaxias" }
    assert_response :success
    assert_includes response.body, I18n.t("questions.show.empty")
    assert_select "p", text: I18n.t("questions.show.scope")
  end

  test "invalid input returns 422 in html and json and stays escaped" do
    get "/questions", params: { question: "<script>alert(1)</script>" + "a" * 501 }
    assert_response :unprocessable_entity
    assert_select "script", text: /alert\(1\)/, count: 0
    get "/questions.json", params: { question: [ "vaccines" ] }
    assert_response :unprocessable_entity
    assert_equal "invalid_question", response.parsed_body["error"]
  end

  test "stored article text is escaped and portuguese results preserve the quality rating" do
    article = Article.create!(url: "https://example.com/unsafe-title", normalized_url: "https://example.com/unsafe-title", host: "example.com", title: "Vacinas infantis <script>alert(1)</script>")
    Investigation.create!(submitted_url: article.url, normalized_url: article.url, root_article: article,
      status: :completed, llm_summary: { "overall_quality" => "strong", "conclusion" => "<script>alert(2)</script>" })
    I18n.with_locale(:"pt-BR") do
      get "/questions", params: { question: "vacinas infantis" }
      assert_response :success
      assert_select "strong", text: I18n.t("investigations.investigation_summary.quality_strong")
      assert_select "script", text: /alert\([12]\)/, count: 0
    end
  end

  test "read-only question search follows public report auth and never triggers URL submission" do
    original = ENV["FRANK_AUTH_SECRET"]
    ENV["FRANK_AUTH_SECRET"] = "question-test-secret"
    assert_no_difference [ "Investigation.count", "Article.count" ] do
      assert_no_enqueued_jobs do
        get "/questions.json", params: { question: "vacinas infantis", url: "https://example.com/never-submit" }
      end
    end
    assert_response :success
  ensure
    ENV["FRANK_AUTH_SECRET"] = original
  end
end
