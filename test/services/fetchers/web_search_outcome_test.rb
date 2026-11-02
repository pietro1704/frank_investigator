require "test_helper"

class Fetchers::WebSearchOutcomeTest < ActiveSupport::TestCase
  test "a genuine empty result is successful while timeouts remain technical failures" do
    searcher = Fetchers::WebSearcher.new(query: SecureRandom.hex, max_results: 5)
    searcher.define_singleton_method(:search_duckduckgo_via_chromium) { [] }
    assert_equal "success", searcher.call_with_status.status
    searcher.define_singleton_method(:search_duckduckgo_via_chromium) { raise Timeout::Error }
    result = searcher.call_with_status
    assert_equal "failed", result.status
    assert_equal "timeout", result.error_code
    assert_empty result.results
    assert_equal [], searcher.call, "legacy callers retain the array interface"
  end

  test "browser challenges and unknown markup are failures but real empty pages are successful" do
    page_class = Struct.new(:body) do
      def go_to(_url); end
    end
    browser_class = Struct.new(:page, :closed) do
      def create_page = page
      def quit = self.closed = true
    end
    { "<div class='anomaly-modal'>Please verify you are human</div>" => "blocked",
      "<html>Unexpected gateway response</html>" => "unavailable",
      "<p>No results found for this query</p>" => nil }.each do |html, error|
      browser = browser_class.new(page_class.new(html), false)
      searcher = Fetchers::WebSearcher.new(query: SecureRandom.hex, max_results: 5)
      searcher.define_singleton_method(:create_browser) { browser }
      searcher.define_singleton_method(:stealth_page!) { |_page| }
      searcher.define_singleton_method(:wait_for_results) { |_page| }
      # Exercise the real browser-path method rather than the suite's global search stub.
      searcher.define_singleton_method(:search_duckduckgo_via_chromium) { original_search_duckduckgo_via_chromium }
      outcome = searcher.call_with_status
      assert_equal(error ? "failed" : "success", outcome.status)
      error ? assert_equal(error, outcome.error_code) : assert_nil(outcome.error_code)
      assert browser.closed, "browser must close even for a challenge or empty response"
    end
  end

  test "blocked responses do not poison a later successful attempt" do
    searcher = Fetchers::WebSearcher.new(query: SecureRandom.hex, max_results: 5)
    searcher.define_singleton_method(:search_duckduckgo_via_chromium) do
      @search_error = "blocked"
      []
    end
    assert_equal "blocked", searcher.call_with_status.error_code
    searcher.define_singleton_method(:search_duckduckgo_via_chromium) { [] }
    assert_equal "success", searcher.call_with_status.status
  end
end
