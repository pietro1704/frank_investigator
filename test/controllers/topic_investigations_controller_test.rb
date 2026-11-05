require "test_helper"

class TopicInvestigationsControllerTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    TopicInvestigation.delete_all
    clear_enqueued_jobs
    @previous_secret = ENV["FRANK_AUTH_SECRET"]
  end
  teardown do
    ENV["FRANK_AUTH_SECRET"] = @previous_secret
    TopicInvestigation.delete_all
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "home offers natural-language investigation without an article URL and preserves archive search" do
    get root_path
    assert_response :success
    assert_select "form[action='/topic_investigations'][method='post'] textarea[name='question'][required]"
    assert_select "#topic-question", count: 1
    assert_select "label[for='topic-question']", count: 1
    assert_select "#question", count: 1
    assert_select "form[action='/topic_investigations'] input[type='url']", count: 0
    assert_select "form[action='/questions'][method='get']"
    assert_select "form#article-analysis input[type='url']"
  end

  test "submitting a question alone redirects to a durable progress report and enqueues matching work" do
    assert_enqueued_with(job: Investigations::DiscoverTopicJob) do
      post topic_investigations_path, params: { question: "Vacinas infantis" }
    end
    assert_response :see_other
    topic = TopicInvestigation.sole
    assert_redirected_to topic_investigation_path(topic)
    assert_equal [ topic.id, topic.run_token ], enqueued_jobs.sole.fetch(:args)
    follow_redirect!
    assert_response :success
    assert_select "meta[http-equiv='refresh'][content='5']"
    assert_select "form[action=?]", cancel_topic_investigation_path(topic)
  end

  test "stored structured scope is visible and escaped during progress" do
    plan = JSON.parse(File.read(Rails.root.join("test/fixtures/files/topic_discovery/structured_plan.json")))
    plan = Investigations::TopicPlan.call(plan)
    plan["scope"] = "<script>scope</script>"
    topic = TopicInvestigation.create!(question: "Schools?", discovery: { "plan" => plan })
    get topic_investigation_path(topic)
    assert_select "[data-research-plan]", count: 1
    assert_select "[data-research-plan] script", count: 0
    assert_includes response.body, "&lt;script&gt;scope&lt;/script&gt;"
    assert_includes response.body, "Left: 2 requested articles"
  end

  test "GET requests remain read only and pending JSON is not ready or cacheable" do
    topic = TopicInvestigation.create!(question: "Vacinas infantis")
    assert_no_difference "TopicInvestigation.count" do
      assert_no_enqueued_jobs do
        get new_topic_investigation_path, params: { question: "Outra pergunta" }
        assert_response :success
        get topic_investigation_path(topic, format: :json), params: { question: "Nunca submeter" }
      end
    end
    assert_response :accepted
    assert_equal false, response.parsed_body.fetch("ready")
    assert_equal "5", response.headers["Retry-After"]
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "Vacinas infantis", topic.reload.question
  end

  test "malformed and oversized inputs are rejected and escaped without creating work" do
    [ nil, [ "vacinas" ], " ", "a" * 501 ].each do |question|
      assert_no_difference "TopicInvestigation.count" do
        post topic_investigations_path(format: :json), params: { question: }
      end
      assert_response :unprocessable_entity
      assert_equal "invalid_question", response.parsed_body.fetch("error")
    end
    post topic_investigations_path, params: { question: "<script>alert(1)</script>" + "a" * 501 }
    assert_response :unprocessable_entity
    assert_select "script", text: /alert\(1\)/, count: 0
    assert_empty enqueued_jobs
  end

  test "submission and mutation require existing basic authentication while reports remain readable" do
    ENV["FRANK_AUTH_SECRET"] = "topic-test-secret"
    topic = TopicInvestigation.create!(question: "Vacinas infantis")
    get new_topic_investigation_path
    assert_response :unauthorized
    post topic_investigations_path, params: { question: "Vacinas infantis" }
    assert_response :unauthorized
    post cancel_topic_investigation_path(topic)
    assert_response :unauthorized
    post restart_topic_investigation_path(topic)
    assert_response :unauthorized
    assert_predicate topic.reload, :queued?
    assert_empty enqueued_jobs
    get topic_investigation_path(topic)
    assert_response :success
    authorization = ActionController::HttpAuthentication::Basic.encode_credentials("pietro", "topic-test-secret")
    post topic_investigations_path(format: :json), params: { question: "Outra pergunta" }, headers: { "HTTP_AUTHORIZATION" => authorization }
    assert_response :accepted
    assert_equal false, response.parsed_body.fetch("ready")
    assert_equal 1, enqueued_jobs.size
  end

  test "completed report uses the Frank summary visual and includes factual verdicts and evidence" do
    topic = completed_topic
    I18n.with_locale(:"pt-BR") do
      get topic_investigation_path(topic)
      assert_response :success
      assert_select "meta[http-equiv='refresh']", count: 0
      assert_select "article", count: 2
      assert_includes response.body, I18n.t("topics.verdicts.supported")
      assert_includes response.body, I18n.t("investigations.investigation_summary.heading")
      assert_select "blockquote", minimum: 3
      assert_select "a[href=?]", topic.discovery.fetch("documents").find { |item| item["id"] == "S1" }.fetch("url")
    end
    get topic_investigation_path(topic, format: :json)
    assert_response :success
    data = response.parsed_body
    assert_equal true, data.fetch("ready")
    assert_equal 0, data.dig("coverage", "pending")
    refute data.fetch("report").key?("model_result")
    assert data.fetch("sources").all? { |item| !item.key?("body") }
    refute data.key?("run_token")
    refute data.key?("lease_token")
    assert_nil response.headers["Retry-After"]
  end

  test "answer precedes details and JSON exposes only cited public evidence" do
    topic = completed_topic
    get topic_investigation_path(topic)
    assert_response :success
    assert_select "[data-topic-answer] h2", text: "What we know"
    assert_select "[data-answer-group='known'] [data-answer-point='S2'] a[target='_blank']", count: 2
    assert response.body.index("data-topic-answer") < response.body.index("data-topic-coverage")
    get topic_investigation_path(topic, format: :json)
    assert_response :success
    assert_equal [ "S2" ], response.parsed_body.dig("answer", "known").pluck("id")
    refute_includes JSON.generate(response.parsed_body["answer"]), '"body"'
  end

  test "consolidated subquestions display their verdicts and literal source citations" do
    root = Rails.root.join("test/fixtures/files/topic_assessment")
    discovery = JSON.parse(File.read(root.join("input.json")))
    report = JSON.parse(File.read(root.join("report.json")))
    raw = JSON.parse(File.read(root.join("synthesis_response.json")))
    model = Object.new
    model.define_singleton_method(:synthesize) { |input:| raw }
    result = Investigations::TopicSynthesis.call(discovery:, report:, model:)
    topic = TopicInvestigation.create!(question: discovery["question"], discovery:, report: result, status: :completed, finished_at: Time.current)
    get topic_investigation_path(topic)
    assert_response :success
    assert_select "[data-subquestion-id='Q1']", count: 1
    assert_select "[data-subquestion-id='Q1'] blockquote", count: raw["sections"].first["evidence"].size
    assert_select "[data-subquestion-id='Q1'] a[target='_blank']", count: raw["sections"].first["evidence"].size
  end

  test "terminal partial HTML and JSON share coverage without polling or private provenance" do
    topic = completed_topic
    plan = Investigations::TopicPlan.call(JSON.parse(file_fixture("topic_discovery/structured_plan.json").read))
    topic.update!(discovery: topic.discovery.merge("plan" => plan),
      report: topic.report.merge("full_analyses" => [ { "source_id" => "S1", "status" => "ready", "evidence_documents" => [ { "body" => "PRIVATE" } ] } ]))
    get topic_investigation_path(topic, format: :json)
    assert_response :ok
    data = response.parsed_body
    assert data["terminal"]
    assert data["report_available"]
    refute data["ready"]
    refute data.dig("coverage", "complete")
    assert_equal plan, data["plan"]
    assert_nil response.headers["Retry-After"]
    refute_includes response.body, "PRIVATE"
    get topic_investigation_path(topic)
    assert_select "[data-partial-result]", count: 1
    assert_select "[data-topic-coverage][data-complete='false']", count: 1
    assert_select "meta[http-equiv='refresh']", count: 0
  end

  test "saved synthesis progress is public but raw checkpoints and generation identities stay private" do
    topic = completed_topic
    topic.update!(status: :failed, error_code: "synthesis_timeout", assessment_checkpoint: { "run_token" => topic.run_token,
      "report" => { "model_result" => "PRIVATE_CHECKPOINT" }, "synthesis" => { "sections" => { "Q1" => {} } } })
    get topic_investigation_path(topic, format: :json)
    assert_response :ok
    assert_equal 1, response.parsed_body.dig("synthesis_progress", "completed")
    refute_includes response.body, "PRIVATE_CHECKPOINT"
    refute_includes response.body, topic.run_token
    refute response.parsed_body.key?("assessment_checkpoint")
    get topic_investigation_path(topic)
    assert_select "[data-synthesis-progress]", count: 1
    assert_select "meta[http-equiv='refresh']", count: 0
  end

  test "stored question source titles and model text are escaped" do
    topic = completed_topic
    payload = topic.discovery.deep_dup
    payload.fetch("documents").each { |item| item["title"] = "<script>alert(2)</script>" }
    topic.update!(discovery: payload, report: topic.report.merge("conclusion" => "<script>alert(3)</script>"))
    get topic_investigation_path(topic)
    assert_response :success
    assert_select "script", text: /alert/, count: 0
    assert_includes response.body, "&lt;script&gt;"
  end

  test "question text cannot escape the document title or inject a script" do
    topic = TopicInvestigation.create!(question: "</title><script>alert(5)</script>")
    get topic_investigation_path(topic)
    assert_response :success
    assert_select "script", text: /alert\(5\)/, count: 0
    assert_select "h1", text: topic.question
  end

  test "cancel and restart fence the previous generation while terminal failures stop polling" do
    topic = TopicInvestigation.create!(question: "Vacinas infantis")
    old = topic.run_token
    post cancel_topic_investigation_path(topic)
    assert_response :see_other
    assert_predicate topic.reload, :cancelled?
    get topic_investigation_path(topic, format: :json)
    assert_response :success
    assert_equal false, response.parsed_body.fetch("ready")
    assert_nil response.headers["Retry-After"]
    assert_enqueued_with(job: Investigations::DiscoverTopicJob) { post restart_topic_investigation_path(topic) }
    assert_not_equal old, topic.reload.run_token
    Investigations::DiscoverTopicJob.perform_now(topic.id, old)
    assert_predicate topic.reload, :queued?
    post restart_topic_investigation_path(topic, format: :json)
    assert_response :conflict
  end

  test "costly submissions are throttled while cancellation remains available" do
    previous_store = Rack::Attack.cache.store
    previous_enabled = Rack::Attack.enabled
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    5.times do
      post topic_investigations_path(format: :json), params: { question: "Vacinas infantis" }
      assert_response :accepted
    end
    assert_no_difference "TopicInvestigation.count" do
      post topic_investigations_path(format: :json), params: { question: "Outra pergunta" }
      assert_response :too_many_requests
    end
    topic = TopicInvestigation.first
    post cancel_topic_investigation_path(topic)
    assert_response :see_other
    assert_predicate topic.reload, :cancelled?
  ensure
    Rack::Attack.cache.store = previous_store
    Rack::Attack.enabled = previous_enabled
  end

  private

  def completed_topic
    directory = Rails.root.join("test/fixtures/files/topic_assessment")
    input = JSON.parse(File.read(directory.join("input.json")))
    report = JSON.parse(File.read(directory.join("report.json")))
    TopicInvestigation.create!(question: input.fetch("question"), status: :completed, stage: "completed",
      discovery: input, report:, finished_at: Time.current)
  end
end
