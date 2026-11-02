require "uri"
require "nokogiri"
require "digest"

module Fetchers
  class WebSearcher
    SearchResult = Struct.new(:url, :title, :snippet, keyword_init: true)
    Outcome = Struct.new(:results, :status, :error_code, keyword_init: true)
    MAX_RESULTS = 8
    CACHE_TTL = 24.hours

    def self.call_with_status(query:, max_results: MAX_RESULTS)
      new(query:, max_results:).call_with_status
    end

    def self.call(query:, max_results: MAX_RESULTS)
      new(query:, max_results:).call
    end

    def initialize(query:, max_results:)
      @query = query.to_s.strip
      @max_results = max_results
    end

    def call
      call_with_status.results
    end

    def call_with_status
      return Outcome.new(results: [], status: "success") if @query.blank?

      cache_key = "web_search:#{Digest::SHA256.hexdigest(@query)}"
      cached = Rails.cache.read(cache_key)
      return Outcome.new(results: cached.first(@max_results), status: "success") if cached

      @search_error = nil
      results = search_duckduckgo_via_chromium
      return Outcome.new(results: [], status: "failed", error_code: @search_error) if @search_error
      results = results.uniq { |r| r.url }
      results = filter_article_urls(results)
      results = results.first(@max_results)

      Rails.cache.write(cache_key, results, expires_in: CACHE_TTL) if results.any?
      Outcome.new(results:, status: "success")
    rescue Timeout::Error, Ferrum::TimeoutError
      Outcome.new(results: [], status: "failed", error_code: "timeout")
    rescue StandardError => error
      Rails.logger.warn("[WebSearcher] Search unavailable (#{error.class.name})")
      Outcome.new(results: [], status: "failed", error_code: "unavailable")
    end

    private

    # Use Chromium to render DuckDuckGo search results page.
    # DuckDuckGo blocks plain Net::HTTP requests (returns 202 with no results),
    # so we must use a real browser to get search results.
    def search_duckduckgo_via_chromium
      search_url = "https://duckduckgo.com/?q=#{ERB::Util.url_encode(@query)}&ia=web"

      browser = create_browser
      begin
        page = browser.create_page
        stealth_page!(page)
        page.go_to(search_url)

        # Wait for search results to render
        wait_for_results(page)

        html = page.body
        results = parse_duckduckgo_results(html)
        if results.empty?
          @search_error = if html.match?(/captcha|anomaly-modal|verify you are human/i)
            "blocked"
          elsif !html.match?(/no results|nenhum resultado|no-results/i)
            "unavailable"
          end
        end
        results
      ensure
        browser.quit
      end
    end

    def parse_duckduckgo_results(html)
      doc = Nokogiri::HTML(html)

      # DuckDuckGo JS-rendered results use data-testid="result-title-a" or
      # article[data-testid="result"] with nested <a> tags
      results = []

      # Try JS-rendered result format
      doc.css('[data-testid="result"]').each do |result_node|
        link = result_node.at_css('[data-testid="result-title-a"]') ||
               result_node.at_css("h2 a") ||
               result_node.at_css("a[href^='http']")
        next unless link

        raw_href = link["href"].to_s
        url = extract_clean_url(raw_href)
        next unless url

        title = link.text.to_s.strip
        snippet_node = result_node.at_css('[data-result="snippet"]') ||
                       result_node.at_css(".snippet") ||
                       result_node.at_css('[data-testid="result-snippet"]')
        snippet = snippet_node&.text.to_s.strip

        results << SearchResult.new(url:, title:, snippet:)
      end

      # Fallback: try HTML lite format (a.result__a)
      if results.empty?
        doc.css("a.result__a").each do |link|
          raw_href = link["href"].to_s
          url = extract_ddg_url(raw_href)
          next unless url

          title = link.text.to_s.strip
          snippet_node = link.ancestors("div").first&.at_css(".result__snippet")
          snippet = snippet_node&.text.to_s.strip

          results << SearchResult.new(url:, title:, snippet:)
        end
      end

      results
    end

    def extract_clean_url(raw_href)
      return nil if raw_href.blank?

      # DuckDuckGo sometimes wraps URLs in redirect
      if raw_href.include?("uddg=")
        return extract_ddg_url(raw_href)
      end

      # Skip internal DuckDuckGo links
      return nil if raw_href.start_with?("/") || raw_href.include?("duckduckgo.com")

      normalize_search_url(raw_href)
    rescue URI::InvalidURIError
      nil
    end

    def extract_ddg_url(raw_href)
      return nil if raw_href.blank?

      if raw_href.include?("uddg=")
        uri = URI.parse(raw_href)
        params = URI.decode_www_form(uri.query.to_s)
        uddg = params.find { |k, _| k == "uddg" }&.last
        return normalize_search_url(uddg) if uddg
      end

      return nil if raw_href.start_with?("/") || raw_href.include?("duckduckgo.com")

      normalize_search_url(raw_href)
    rescue URI::InvalidURIError
      nil
    end

    def normalize_search_url(url)
      return nil if url.blank?

      url = CGI.unescape(url) if url.include?("%")
      uri = URI.parse(url)
      return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      return nil if uri.host.blank?

      Investigations::UrlNormalizer.call(url)
    rescue URI::InvalidURIError, Investigations::UrlNormalizer::InvalidUrlError
      nil
    end

    def filter_article_urls(results)
      results.select do |result|
        Investigations::UrlClassifier.call(result.url)
      rescue Investigations::UrlClassifier::RejectedUrlError
        false
      end
    end

    def wait_for_results(page)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      loop do
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        count = page.evaluate(<<~JS) rescue 0
          document.querySelectorAll('[data-testid="result"]').length +
          document.querySelectorAll('a.result__a').length
        JS
        break if count > 0
        sleep 0.5
      end
    rescue Ferrum::TimeoutError
      # Proceed with whatever we have
    end

    def create_browser
      Ferrum::Browser.new(
        headless: "new",
        timeout: 20,
        process_timeout: 25,
        browser_path: ENV.fetch("CHROMIUM_PATH", "chromium"),
        browser_options: {
          "no-sandbox" => nil,
          "disable-setuid-sandbox" => nil,
          "disable-gpu" => nil,
          "disable-dev-shm-usage" => nil,
          "no-first-run" => nil,
          "no-default-browser-check" => nil,
          "disable-blink-features" => "AutomationControlled",
          "window-size" => "1440,900",
          "lang" => "pt-BR,pt,en-US,en"
        }
      )
    end

    def stealth_page!(page)
      ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"
      page.headers.set({
        "User-Agent" => ua,
        "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language" => "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7"
      })

      page.command("Page.addScriptToEvaluateOnNewDocument", source: <<~JS)
        Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
        Object.defineProperty(navigator, 'languages', { get: () => ['pt-BR', 'pt', 'en-US', 'en'] });
        window.chrome = { runtime: {}, loadTimes: function(){}, csi: function(){} };
      JS
    end
  end
end
