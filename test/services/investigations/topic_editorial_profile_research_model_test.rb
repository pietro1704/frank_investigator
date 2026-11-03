require "test_helper"

class Investigations::TopicEditorialProfileResearchModelTest < ActiveSupport::TestCase
  test "provider uses the observed profile schema and publication evidence allowlist" do
    options = Rails.configuration.x.frank_investigator
    previous = [ options.llm_provider, options.llm_models, ENV["OPENROUTER_API_KEY"], RubyLLM.config.openrouter_api_key ]
    options.llm_provider = "openrouter"
    options.llm_models = [ "openai/gpt-5-mini" ]
    ENV["OPENROUTER_API_KEY"] = RubyLLM.config.openrouter_api_key = "test-editorial-profile"
    response = JSON.parse(file_fixture("topic_discovery/editorial_profile.json").read)
    publication = { "host" => "jacobin.com", "article_url" => "https://jacobin.com/about" }
    documents = [ { "id" => "P1", "url" => "https://jacobin.com/about", "body" => response["evidence"].sole["quote"], "relation" => "publisher_statement" } ]
    captured = nil
    request = stub_request(:post, LlmStubs::OPENROUTER_URL).to_return do |http|
      captured = JSON.parse(http.body)
      { status: 200, headers: { "Content-Type" => "application/json" }, body: {
        id: "profile-observed", model: captured["model"], choices: [ { message: { role: "assistant", content: response.to_json }, finish_reason: "stop" } ],
        usage: { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 }
      }.to_json }
    end
    actual = Investigations::TopicDiscovery::ResearchModel.new.editorial_profile(publication: publication, documents: documents)
    assert_equal response, actual
    assert_equal "topic_editorial_profile", captured.dig("response_format", "json_schema", "name")
    schema = captured.dig("response_format", "json_schema", "schema")
    assert_equal [ "P1" ], schema.dig("properties", "evidence", "items", "properties", "source_id", "enum")
    assert_includes captured["messages"].last["content"], JSON.generate(documents)
    assert_requested request, times: 1
  ensure
    options.llm_provider, options.llm_models, ENV["OPENROUTER_API_KEY"], RubyLLM.config.openrouter_api_key = previous if previous
  end
end
