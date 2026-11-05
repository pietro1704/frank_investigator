require "test_helper"

class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  test "a first visit has a nonempty nonce shared by the CSP and importmap scripts" do
    topic = TopicInvestigation.create!(question: "What is known?")
    get topic_investigation_path(topic)
    assert_response :success
    policy = response.headers.fetch("Content-Security-Policy")
    nonce = policy[/\bnonce-([^']*)'/, 1]
    assert nonce.present?, "an empty session ID must not disable Turbo on the first visit"
    assert_select "script[type='importmap'][nonce=?]", nonce
    assert_select "script[type='module'][nonce=?]", nonce
    refute_includes policy, "unsafe-inline"
    get topic_investigation_path(topic)
    assert_not_equal nonce, response.headers.fetch("Content-Security-Policy")[/\bnonce-([^']*)'/, 1]
  end
end
