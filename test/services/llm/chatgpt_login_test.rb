require "test_helper"
require "tmpdir"

class Llm::ChatgptLoginTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir("frank-chatgpt-login")
    @credentials = Llm::Chatgpt::Credentials.new(directory: @directory, account: "main")
    @key = OpenSSL::PKey::RSA.generate(2048)
    stub_request(:get, "https://auth.openai.com/.well-known/jwks.json").to_return(status: 200, body: JSON.generate(keys: [ {
      kid: "test-key", kty: "RSA", n: encode(@key.n.to_s(2)), e: encode(@key.e.to_s(2))
    } ]))
    @login = Llm::Chatgpt::Login.new(credentials: @credentials, redirect_uri: "http://127.0.0.1:23456/auth/callback")
    @params = URI.decode_www_form(URI(@login.authorization_url).query).to_h
  end

  teardown do
    FileUtils.remove_entry(@directory)
  end

  test "PKCE sign-in validates signed identity and stores the issued registration privately" do
    assert_equal "dynamic_agent_client", @params["client_id"]
    assert_equal "Frank Investigator", @params["agent_name_hint"]
    assert_includes @params["scope"].split, "chatgpt.tokens.use.direct"
    token_stub = stub_tokens
    data = @login.complete(callback)
    assert_equal "oaiapp_registered", data.fetch("client_id")
    assert_equal "subject-main", data.fetch("subject")
    assert @credentials.available?
    assert_equal 0o600, File.stat(@credentials.path).mode & 0o777
    assert_requested token_stub
  end

  test "cancelled authorization and mismatched state never exchange a code" do
    error = assert_raises(Llm::Chatgpt::Error) { @login.complete(callback.merge("error" => "access_denied")) }
    assert_equal "authorization_cancelled", error.code
    error = assert_raises(Llm::Chatgpt::Error) { @login.complete(callback.merge("state" => "other")) }
    assert_equal "invalid_oauth_state", error.code
    assert_not @credentials.available?
    assert_not_requested :post, "https://auth.openai.com/api/accounts/oauth/token"
  end

  test "an issued client is mandatory for a new registration" do
    assert_raises(Llm::Chatgpt::Error) { @login.complete(callback.except("client_id")) }
    assert_raises(Llm::Chatgpt::Error) { @login.complete(callback.merge("client_id" => "dynamic_agent_client")) }
    assert_not_requested :post, "https://auth.openai.com/api/accounts/oauth/token"
  end

  test "identity-only consent is saved without enabling inference" do
    stub_tokens(scope: "openid email")
    @login.complete(callback)
    assert_equal "subject-main", @credentials.read.fetch("subject")
    assert_not @credentials.available?
    assert_raises(Llm::Chatgpt::Error) { @credentials.access_token }
  end

  test "wrong signature audience expiry issuer or nonce cannot create credentials" do
    [ { "aud" => "other-client" }, { "nonce" => "other-nonce" }, { "exp" => 0 }, { "iss" => "https://attacker.example" }, { "aud" => [ "oaiapp_registered", "other-client" ], "azp" => "other-client" } ].each do |changes|
      stub_tokens(claims: changes)
      assert_raises(Llm::Chatgpt::Error) { @login.complete(callback) }
      assert_not @credentials.path.exist?
    end
    valid = identity_token
    bad_signature = valid.split(".").first(2).join(".") + "." + encode("bad signature")
    stub_tokens(id_token: bad_signature)
    assert_raises(Llm::Chatgpt::Error) { @login.complete(callback) }
    assert_not @credentials.path.exist?
  end

  test "an expired authorization code retains only the issued registration for retry" do
    stub_request(:post, "https://auth.openai.com/api/accounts/oauth/token").to_return(status: 400, body: JSON.generate(error: "invalid_grant"))
    error = assert_raises(Llm::Chatgpt::Error) { @login.complete(callback) }
    assert_equal "invalid_grant", error.code
    assert_equal "oaiapp_registered", @credentials.read.fetch("client_id")
    assert_not @credentials.available?
    retry_login = Llm::Chatgpt::Login.new(credentials: @credentials, redirect_uri: "http://127.0.0.1:34567/auth/callback")
    params = URI.decode_www_form(URI(retry_login.authorization_url).query).to_h
    assert_equal "oaiapp_registered", params["client_id"]
    assert_not params.key?("agent_name_hint")
    assert_not_equal @login.state, retry_login.state
  end

  test "returning sign-in reuses host and client and refuses another account identity" do
    stub_tokens
    original = @login.complete(callback)
    returning = Llm::Chatgpt::Login.new(credentials: @credentials, redirect_uri: "http://127.0.0.1:34567/auth/callback")
    @params = URI.decode_www_form(URI(returning.authorization_url).query).to_h
    assert_equal "oaiapp_registered", @params["client_id"]
    assert_equal original.fetch("ext_agent_host_id"), @params["ext_agent_host_id"]
    assert_not @params.key?("agent_name_hint")
    assert_not_equal @login.state, returning.state
    stub_tokens(claims: { "sub" => "different-user" })
    assert_raises(Llm::Chatgpt::Error) { returning.complete(callback.merge("state" => returning.state)) }
    assert_equal original, @credentials.read
    assert_raises(Llm::Chatgpt::Error) { returning.complete(callback.merge("state" => returning.state, "client_id" => "other-client")) }
    assert_equal original, @credentials.read
  end

  test "refreshing with another identity never replaces the selected account" do
    stub_tokens
    original = @login.complete(callback)
    @credentials.write(original.merge("expires_at" => 0))
    stub_request(:post, "https://auth.openai.com/api/accounts/oauth/token").to_return(status: 200, body: JSON.generate(
      access_token: "wrong-access", refresh_token: "wrong-refresh", expires_in: 3600,
      id_token: identity_token("sub" => "other-subject")
    ))
    assert_raises(Llm::Chatgpt::Error) { @credentials.access_token }
    assert_equal "plan-token", @credentials.read.fetch("access_token")
    assert_equal "subject-main", @credentials.read.fetch("subject")
  end

  test "sign out revokes only this registration and clears tokens even if revocation fails" do
    stub_tokens
    original = @login.complete(callback)
    stub_request(:get, "https://auth.openai.com/.well-known/openid-configuration").to_return(status: 200, body: JSON.generate(revocation_endpoint: "https://auth.openai.com/api/accounts/oauth/revoke"))
    stub_request(:post, "https://auth.openai.com/api/accounts/oauth/revoke").with(body: {
      token: "refresh-token", token_type_hint: "refresh_token", client_id: "oaiapp_registered"
    }).to_return(status: 200, body: "")
    assert @credentials.sign_out
    assert_equal "oaiapp_registered", @credentials.read.fetch("client_id")
    assert_not @credentials.read.key?("access_token")
    assert_not @credentials.read.key?("id_token")
    @credentials.write(original)
    stub_request(:post, "https://auth.openai.com/api/accounts/oauth/revoke").to_return(status: 503, body: "unavailable")
    assert_not @credentials.sign_out
    assert_not @credentials.available?
    assert_not @credentials.read.key?("refresh_token")
  end

  test "loopback listener completes an actual HTTP callback without exposing credentials to the browser" do
    browser = nil
    test_case = self
    launch = lambda do |url|
      params = URI.decode_www_form(URI(url).query).to_h
      test_case.instance_variable_set(:@params, params)
      test_case.send(:stub_tokens)
      callback_uri = URI(params.fetch("redirect_uri"))
      callback_uri.query = URI.encode_www_form(test_case.send(:callback).merge("state" => params.fetch("state")))
      browser = Thread.new { Net::HTTP.get_response(callback_uri) }
    end
    data = nil
    original = Llm::Chatgpt::Login.method(:open_browser)
    Llm::Chatgpt::Login.define_singleton_method(:open_browser, launch)
    capture_io do
      data = Llm::Chatgpt::Login.run(credentials: @credentials, timeout: 5)
    end
    response = browser.value
    assert_equal "200", response.code
    assert_equal "no-store", response["Cache-Control"]
    assert_not_includes response.body, "plan-token"
    assert_not_includes response.body, "refresh-token"
    assert_equal "subject-main", data.fetch("subject")
  ensure
    Llm::Chatgpt::Login.define_singleton_method(:open_browser, original) if original
    browser&.join(5)
  end

  private

  def callback
    { "state" => @login.state, "code" => "test-authorization-code", "client_id" => "oaiapp_registered" }
  end

  def identity_token(changes = {})
    claims = { "iss" => "https://auth.openai.com", "aud" => "oaiapp_registered", "exp" => Time.now.to_i + 3600,
      "sub" => "subject-main", "email" => "person@example.com", "nonce" => @params.fetch("nonce") }.merge(changes)
    signing_input = [ encode(JSON.generate(alg: "RS256", kid: "test-key")), encode(JSON.generate(claims)) ].join(".")
    signing_input + "." + encode(@key.sign(OpenSSL::Digest::SHA256.new, signing_input))
  end

  def stub_tokens(scope: "openid email chatgpt.tokens.use.direct", claims: {}, id_token: identity_token(claims))
    stub_request(:post, "https://auth.openai.com/api/accounts/oauth/token").with do |request|
      body = URI.decode_www_form(request.body).to_h
      assert_equal "oaiapp_registered", body["client_id"]
      assert_equal @params.fetch("redirect_uri"), body["redirect_uri"]
      assert_equal "authorization_code", body["grant_type"]
      assert_equal "https://api.openai.com/v1", body["resource"]
      assert_equal @params.fetch("code_challenge"), encode(Digest::SHA256.digest(body.fetch("code_verifier")))
      true
    end.to_return(status: 200, body: JSON.generate(access_token: "plan-token", refresh_token: "refresh-token", expires_in: 3600, scope:, id_token:))
  end

  def encode(value)
    Base64.urlsafe_encode64(value, padding: false)
  end
end
