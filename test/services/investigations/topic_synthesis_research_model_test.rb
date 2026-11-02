require "test_helper"

class Investigations::TopicSynthesisResearchModelTest < ActiveSupport::TestCase
  test "configured provider receives the live-observed synthesis schema and corpus" do
    options = Rails.configuration.x.frank_investigator
    previous = [ options.llm_provider, options.llm_models, ENV["OPENROUTER_API_KEY"], RubyLLM.config.openrouter_api_key ]
    options.llm_provider = "openrouter"
    options.llm_models = [ "anthropic/claude-sonnet-4-6" ]
    ENV["OPENROUTER_API_KEY"] = "test-synthesis"
    RubyLLM.config.openrouter_api_key = "test-synthesis"
    root = Rails.root.join("test/fixtures/files/topic_assessment")
    input = JSON.parse(File.read(root.join("synthesis_input.json")))
    response = JSON.parse(File.read(root.join("synthesis_response.json")))
    captured = nil
    request = stub_request(:post, LlmStubs::OPENROUTER_URL).to_return do |http|
      captured = JSON.parse(http.body)
      { status: 200, headers: { "Content-Type" => "application/json" }, body: {
        id: "synthesis-captured", model: captured.fetch("model"),
        choices: [ { message: { role: "assistant", content: response.to_json }, finish_reason: "stop" } ],
        usage: { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 }
      }.to_json }
    end
    assert_equal response, Investigations::TopicSynthesis::ResearchModel.new.synthesize(input:)
    assert_equal "topic_synthesis", captured.dig("response_format", "json_schema", "name")
    assert_includes captured.fetch("messages").last.fetch("content"), JSON.generate(input)
    assert_requested request, times: 1
    assert_not_requested :post, "https://api.openai.com/v1/chat/completions"
  ensure
    options.llm_provider, options.llm_models, ENV["OPENROUTER_API_KEY"], RubyLLM.config.openrouter_api_key = previous if previous
  end
end
