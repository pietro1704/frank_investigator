require "test_helper"

class Investigations::TopicDiscoveryResearchModelTest < ActiveSupport::TestCase
  FIXTURES = Rails.root.join("test/fixtures/files/topic_discovery")

  setup do
    options = Rails.configuration.x.frank_investigator
    @previous_provider = options.llm_provider
    @previous_models = options.llm_models
    @previous_key = ENV["OPENROUTER_API_KEY"]
    @previous_client_key = RubyLLM.config.openrouter_api_key
    options.llm_provider = "openrouter"
    options.llm_models = [ "anthropic/claude-sonnet-4-6" ]
    ENV["OPENROUTER_API_KEY"] = "test-topic-research"
    RubyLLM.config.openrouter_api_key = "test-topic-research"
    @requests = []
    @payloads = {
      "topic_research_plan" => fixture("plan"),
      "topic_source_screen" => fixture("screen"),
      "topic_document_kinds" => fixture("classification")
    }
    @request_stub = stub_request(:post, LlmStubs::OPENROUTER_URL).to_return do |request|
      body = JSON.parse(request.body)
      @requests << body
      name = body.dig("response_format", "json_schema", "name")
      { status: 200, headers: { "Content-Type" => "application/json" }, body: {
        id: "topic-research-fixture", model: body.fetch("model"),
        choices: [ { message: { role: "assistant", content: JSON.generate(@payloads.fetch(name)) }, finish_reason: "stop" } ],
        usage: { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 }
      }.to_json }
    end
    @client = Investigations::TopicDiscovery::ResearchModel.new
  end

  teardown do
    options = Rails.configuration.x.frank_investigator
    options.llm_provider = @previous_provider
    options.llm_models = @previous_models
    ENV["OPENROUTER_API_KEY"] = @previous_key
    RubyLLM.config.openrouter_api_key = @previous_client_key
  end

  test "uses the configured provider with the three live-observed structured schemas" do
    question = "O desmatamento na Amazônia caiu em 2024?"
    documents = fixture("documents")
    assert_equal fixture("plan"), @client.plan(question:)
    assert_equal fixture("screen"), @client.screen(question:, scope: fixture("plan").fetch("scope"), documents: documents.first(5))
    assert_equal fixture("classification"), @client.classify(question:, documents:)

    assert_equal %w[topic_research_plan topic_source_screen topic_document_kinds], @requests.map { |request| request.dig("response_format", "json_schema", "name") }
    assert @requests.all? { |request| request.fetch("model") == "anthropic/claude-sonnet-4-6" }
    assert @requests.all? { |request| request.fetch("messages").last.fetch("content").include?(JSON.generate(question)) }
    assert_requested @request_stub, times: 3
    assert_not_requested :post, "https://api.openai.com/v1/chat/completions"
  end

  test "unavailable configured provider fails without attempting another provider" do
    ENV.delete("OPENROUTER_API_KEY")
    assert_raises(Investigations::TopicDiscovery::Unavailable) { @client.plan(question: "Vacinas infantis") }
    assert_empty @requests
    assert_not_requested :post, LlmStubs::OPENROUTER_URL
    assert_not_requested :post, "https://api.openai.com/v1/chat/completions"
  end

  private

  def fixture(name)
    JSON.parse(File.read(FIXTURES.join("#{name}.json")))
  end
end
