require "test_helper"
require "tmpdir"

class Llm::ChatgptTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir("frank-chatgpt")
    @credentials = Llm::Chatgpt::Credentials.new(directory: @directory, account: "main")
  end

  teardown do
    FileUtils.remove_entry(@directory)
  end

  test "subscription mode never uses an API key or paid embeddings" do
    options = Rails.configuration.x.frank_investigator
    previous = options.llm_provider
    options.llm_provider = "chatgpt"
    assert_equal "chatgpt", Llm::ProviderConfig.provider
    assert_instance_of Llm::Chatgpt::Chat, Llm::ProviderConfig.chat(model: "test-model")
    assert_not SqliteVec.enabled?
  ensure
    options.llm_provider = previous
  end

  test "an unconnected account does not become available because an API key exists" do
    previous_openai = ENV["OPENAI_API_KEY"]
    previous_openrouter = ENV["OPENROUTER_API_KEY"]
    ENV["OPENAI_API_KEY"] = "api-key-must-not-be-used"
    ENV["OPENROUTER_API_KEY"] = "router-key-must-not-be-used"
    assert_not @credentials.available?
    assert_raises(Llm::Chatgpt::Error) { @credentials.access_token }
    assert_raises(Llm::Chatgpt::Error) { chat.ask("test") }
    assert_not_requested :post, "https://api.openai.com/v1/chat/completions"
    assert_not_requested :post, "https://openrouter.ai/api/v1/chat/completions"
  ensure
    ENV["OPENAI_API_KEY"] = previous_openai
    ENV["OPENROUTER_API_KEY"] = previous_openrouter
  end

  test "completed streamed responses preserve structured content and usage" do
    save_credentials
    stub_request(:post, "https://api.openai.com/v1/responses").with do |request|
      body = JSON.parse(request.body)
      assert_equal "Bearer plan-token", request.headers["Authorization"]
      assert_equal false, body["store"]
      assert_equal true, body["stream"]
      assert_equal [ { "role" => "user", "content" => "Check this claim" } ], body["input"]
      assert_equal "Assess evidence", body["instructions"]
      assert_equal "json_schema", body.dig("text", "format", "type")
      assert_not body.key?("temperature")
      true
    end.to_return(status: 200, body: stream("response.completed", {
      "status" => "completed",
      "output" => [ { "content" => [ { "type" => "output_text", "text" => '{"verdict":"mixed"}' } ] } ],
      "usage" => { "input_tokens" => 10, "output_tokens" => 4 }
    }))
    result = chat.with_instructions("Assess evidence").with_schema(
      name: "assessment", schema: { type: "object", properties: { verdict: { type: "string" } }, required: [ "verdict" ], additionalProperties: false }
    ).ask("Check this claim")
    assert_equal({ "verdict" => "mixed" }, result.content)
    assert_equal 10, result.tokens.input
    assert_equal 4, result.tokens.output
  end

  test "live subscription stream retains done items when the terminal output is empty" do
    save_credentials
    # Captured from the official ChatGPT plan route; account and response IDs removed.
    body = Rails.root.join("test/fixtures/files/chatgpt_plan_completed.sse").read
    stub_request(:post, "https://api.openai.com/v1/responses").to_return(status: 200, body:)
    result = chat.with_schema(Llm::RubyLlmClient.new.send(:response_schema)).ask("Assess the supplied IBGE evidence")
    assert_equal "supported", result.content.fetch("verdict")
    assert_includes result.content.fetch("reason_summary"), "4,83%"
    assert_equal 205, result.tokens.input
    assert_equal 65, result.tokens.output
  end

  test "a complete output item followed by response failure is never published" do
    save_credentials
    item = {
      type: "response.output_item.done", output_index: 0,
      item: { type: "message", status: "completed", role: "assistant", content: [ { type: "output_text", text: "provisional result" } ] }
    }
    body = "data: #{JSON.generate(item)}\n\n" + stream("response.failed", { "error" => { "code" => "server_error" } })
    stub_request(:post, "https://api.openai.com/v1/responses").to_return(status: 200, body:)
    assert_raises(Llm::Chatgpt::Error) { chat.ask("test") }
  end

  test "partial text followed by a limit failure is never accepted as success" do
    save_credentials
    body = "data: #{JSON.generate(type: 'response.output_text.delta', delta: '{\"verdict\":\"supported\"}')}\n\n"
    body += stream("response.failed", { "status" => "failed", "error" => { "code" => "subscription_sharing_usage_limit_exceeded" } })
    stub_request(:post, "https://api.openai.com/v1/responses").to_return(status: 200, body:)
    error = assert_raises(Llm::Chatgpt::Error) { chat.ask("test") }
    assert_equal "subscription_sharing_usage_limit_exceeded", error.code
    assert_not @credentials.available?
    assert_raises(Llm::Chatgpt::Error) { chat.ask("another request") }
    assert_requested :post, "https://api.openai.com/v1/responses", times: 1
    assert_not_requested :post, "https://api.openai.com/v1/chat/completions"
    @credentials.resume_usage
    assert @credentials.available?
    assert_equal "refresh-old", @credentials.read.fetch("refresh_token")
  end

  test "cancelled and truncated streams fail closed" do
    save_credentials
    [ "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n", stream("response.incomplete", { "status" => "incomplete" }) ].each do |body|
      stub_request(:post, "https://api.openai.com/v1/responses").to_return(status: 200, body:)
      assert_raises(Llm::Chatgpt::Error) { chat.ask("test") }
    end
  end

  test "HTTP errors preserve status and code without exposing bearer tokens" do
    save_credentials
    stub_request(:post, "https://api.openai.com/v1/responses").to_return(
      status: 403, headers: { "x-request-id" => "test-request" }, body: JSON.generate(error: { code: "subscription_sharing_user_not_eligible", message: "plan-token" })
    )
    error = assert_raises(Llm::Chatgpt::Error) { chat.ask("test") }
    assert_equal 403, error.status
    assert_equal "subscription_sharing_user_not_eligible", error.code
    assert_equal "test-request", error.request_id
    assert_not_includes error.message, "plan-token"
  end

  test "expired sessions refresh with their issued client and rotate tokens atomically" do
    save_credentials(expires_at: 0)
    stub_request(:post, "https://auth.openai.com/api/accounts/oauth/token").with(body: {
      "grant_type" => "refresh_token", "client_id" => "oaiapp_main", "refresh_token" => "refresh-old", "resource" => "https://api.openai.com/v1"
    }).to_return(status: 200, body: JSON.generate(access_token: "plan-new", refresh_token: "refresh-new", expires_in: 3600))
    assert_equal "plan-new", @credentials.access_token
    assert_equal "refresh-new", @credentials.read.fetch("refresh_token")
    assert_equal 0o600, File.stat(@credentials.path).mode & 0o777
    assert_equal "plan-new", @credentials.access_token
    assert_requested :post, "https://auth.openai.com/api/accounts/oauth/token", times: 1
  end

  test "account labels cannot escape credential storage" do
    assert_raises(ArgumentError) { Llm::Chatgpt::Credentials.new(directory: @directory, account: "../other") }
  end

  test "simultaneous workers serialize a rotating refresh token" do
    save_credentials(expires_at: 0)
    stub_request(:post, "https://auth.openai.com/api/accounts/oauth/token").to_return do
      sleep 0.02
      { status: 200, body: JSON.generate(access_token: "plan-new", refresh_token: "refresh-new", expires_in: 3600) }
    end
    results = 3.times.map do
      Thread.new { Llm::Chatgpt::Credentials.new(directory: @directory, account: "main").access_token }
    end.map(&:value)
    assert_equal [ "plan-new" ] * 3, results
    assert_requested :post, "https://auth.openai.com/api/accounts/oauth/token", times: 1
  end

  test "a revoked refresh grant clears this account's tokens without falling back" do
    save_credentials(expires_at: 0)
    stub_request(:post, "https://auth.openai.com/api/accounts/oauth/token").to_return(status: 400, body: JSON.generate(error: "invalid_grant"))
    error = assert_raises(Llm::Chatgpt::Error) { @credentials.access_token }
    assert_equal "invalid_grant", error.code
    assert_equal "user-main", @credentials.read.fetch("subject")
    assert_not @credentials.read.key?("access_token")
    assert_not @credentials.available?
    assert_raises(Llm::Chatgpt::Error) { @credentials.access_token }
    assert_requested :post, "https://auth.openai.com/api/accounts/oauth/token", times: 1
  end

  test "subscription mode cannot enqueue an embedding API request" do
    options = Rails.configuration.x.frank_investigator
    previous = options.llm_provider
    options.llm_provider = "chatgpt"
    assert_nil Investigations::EmbeddingIndexer.call(investigation: Investigation.new)
    assert_not_requested :post, "https://api.openai.com/v1/embeddings"
    assert_not_requested :post, "https://openrouter.ai/api/v1/embeddings"
  ensure
    options.llm_provider = previous
  end

  private

  def save_credentials(expires_at: Time.now.to_i + 3600)
    @credentials.write({ "client_id" => "oaiapp_main", "subject" => "user-main", "access_token" => "plan-token", "refresh_token" => "refresh-old", "scopes" => [ "chatgpt.tokens.use.direct" ], "expires_at" => expires_at })
  end

  def chat
    Llm::Chatgpt::Chat.new(model: "test-model", credentials: @credentials)
  end

  def stream(type, response)
    "event: #{type}\r\ndata: #{JSON.generate(type:, response:)}\r\n\r\n"
  end
end
