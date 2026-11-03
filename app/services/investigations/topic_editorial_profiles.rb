module Investigations
  # Publisher identity and documentary evidence are separate from article quality.
  class TopicEditorialProfiles
    MAX_PUBLISHERS = 8
    MAX_PROFILE_PAGES = 2
    TRUSTED_REVIEWERS = %w[allsides.com adfontesmedia.com mediabiasfactcheck.com].freeze
    ABOUT_PATH = /(?:about|quem[-_]somos|sobre[-_](?:nos|nós|a-|o-)|miss[aã]o|mission|principles)/i
    attr_reader :profiles

    def self.hints
      YAML.load_file(Rails.root.join("config/topic_editorial_search.yml"))
    end

    def self.publisher_key(host)
      normalized = host.to_s.downcase.delete_prefix("www.")
      hint = hints.values.flatten.find do |entry|
        [ entry["host"], *Array(entry["aliases"]) ].any? { |domain| normalized == domain || normalized.end_with?(".#{domain}") }
      end
      hint ? hint.fetch("host") : normalized
    end

    def self.queries(plan)
      original = plan.fetch("news_queries")
      counts = plan.dig("requirements", "editorial_counts") || {}
      return original unless counts.values.sum.positive?
      directed = []
      counts.each do |side, count|
        next unless count.positive?
        Array(hints[side]).first(2).each do |hint|
          query = hint["language"] == "en" ? original.last : original[(directed.size + 2) % original.size]
          directed << "#{query} site:#{hint.fetch('host')}"
        end
      end
      (original.first([ 8 - directed.size, 1 ].max) + directed).uniq.first(8)
    end

    def self.publisher_pages(html, url)
      host = publisher_key(URI.parse(url).host)
      Nokogiri::HTML(html).css("a[href]").filter_map do |link|
        uri = URI.join(url, link["href"])
        next unless %w[http https].include?(uri.scheme) && uri.userinfo.nil?
        next unless publisher_key(uri.host) == host && uri.path.match?(ABOUT_PATH)
        uri.fragment = nil
        uri.to_s
      rescue URI::InvalidURIError
        nil
      end.uniq.first(2)
    end

    def initialize(model:, fetcher:, on_progress: ->(*) { })
      @model, @fetcher, @on_progress = model, fetcher, on_progress
      @profiles = {}
      @profile_seconds = 0.0
    end

    def enrich(document)
      return unless document["kind"] == "news_article"
      host = self.class.publisher_key(URI.parse(document.fetch("url")).host)
      profile = @profiles[host]
      unless profile
        return if document["editorial_confidence"] == "documented" || @profiles.size >= MAX_PUBLISHERS || @profile_seconds >= 180
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          profile = resolve(host, document)
        ensure
          @profile_seconds += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        end
        @profiles[host] = profile
        @on_progress.call
      end
      return unless profile["confidence"] == "documented"
      if document["editorial_confidence"] == "documented" && document["editorial_position"] != profile["position"]
        document.merge!("editorial_position" => "unknown", "editorial_confidence" => "unknown", "editorial_reason" => "conflicting_editorial_evidence")
      else
        document.merge!("editorial_position" => profile["position"], "editorial_confidence" => "documented", "editorial_reason" => profile["reason"])
      end
      document["editorial_profile"] = profile.deep_dup
    end

    def priority(candidate, missing)
      host = self.class.publisher_key(URI.parse(candidate.url).host)
      profile = @profiles[host]
      return 0 unless profile && profile["confidence"] == "documented"
      missing.fetch(profile["position"], 0).positive? ? -1 : 1
    end

    private

    def resolve(host, article)
      hints = self.class.hints.values.flatten.select { |hint| host == hint["host"] }
      urls = (Array(article["publisher_pages"]).first(1) + hints.flat_map { |hint| Array(hint["profile_urls"]) } + hints.pluck("profile_url") + Array(article["publisher_pages"]).drop(1)).uniq.first(MAX_PROFILE_PAGES)
      documents = urls.filter_map do |url|
        @on_progress.call
        begin
          normalized = UrlNormalizer.call(url)
          profile_uri = URI.parse(normalized)
          next if profile_uri.userinfo.present?
          profile_host = profile_uri.host.to_s.delete_prefix("www.")
          own = self.class.publisher_key(profile_host) == host
          next unless own || TRUSTED_REVIEWERS.any? { |reviewer| profile_host == reviewer || profile_host.end_with?(".#{reviewer}") }
          snapshot = @fetcher.call(normalized)
          @on_progress.call
          unless own
            linked_hosts = Nokogiri::HTML(snapshot.html).css("a[href]").filter_map do |link|
              URI.parse(link["href"]).host&.delete_prefix("www.")
            rescue URI::InvalidURIError
              nil
            end
            next unless linked_hosts.any? { |linked| self.class.publisher_key(linked) == host }
          end
          parsed = Parsing::MainContentExtractor.call(html: snapshot.html, url: normalized)
          next if parsed.body_text.to_s.length < 200
          unless own
            title = parsed.title.to_s.downcase.gsub(/[^[:alnum:]]/, "")
            names = [ host.split(".").first, Sources::ProfileRegistry.match(host)&.name, *hints.pluck("name") ].compact
            next unless names.any? { |name| title.include?(name.downcase.gsub(/[^[:alnum:]]/, "")) }
          end
          { "id" => "P#{urls.index(url) + 1}", "url" => normalized, "title" => parsed.title, "body" => parsed.body_text.first(6000),
            "relation" => own ? "publisher_statement" : "external_assessment", "checked_at" => Time.current.iso8601 }
        rescue UrlNormalizer::InvalidUrlError, Fetchers::ChromiumFetcher::FetchError, Ferrum::StatusError, Timeout::Error
          nil
        end
      end
      unknown = { "host" => host, "position" => "unknown", "confidence" => "unknown", "reason" => "no_documented_profile", "evidence" => [] }
      return unknown if documents.empty?
      @on_progress.call
      raw = Timeout.timeout(30) do
        @model.editorial_profile(publication: { "host" => host, "article_url" => article["url"] }, documents: documents.deep_dup)
      end
      @on_progress.call
      return unknown unless raw.is_a?(Hash) && raw.keys.sort == %w[editorial_confidence editorial_position editorial_reason evidence].sort
      return unknown unless raw["editorial_confidence"] == "documented" && TopicPlan::SIDES.include?(raw["editorial_position"])
      return unknown unless raw["editorial_reason"].is_a?(String) && raw["editorial_reason"].strip.length.between?(20, 2000)
      evidence = raw["evidence"]
      return unknown unless evidence.is_a?(Array) && evidence.size.between?(1, MAX_PROFILE_PAGES)
      citations = evidence.map do |item|
        source = documents.find { |entry| entry["id"] == item["source_id"] } if item.is_a?(Hash)
        return unknown unless source && item["quote"].is_a?(String) && item["quote"].strip.length.between?(20, 1000) && source["body"].squish.include?(item["quote"].squish)
        source.except("body").merge("quote" => item["quote"], "body_digest" => Digest::SHA256.hexdigest(source["body"]))
      end
      if raw["editorial_position"] == "center"
        explicit = citations.any? do |item|
          centrist = item["quote"].match?(/\b(?:centrist(?:a|as)?|center|centre|centro)\b/i) && !item["quote"].match?(/(?:cent(?:er|re|ro)[ -](?:left|right|esquerda|direita)|(?:left|right)[ -]cent(?:er|re))/i)
          reviewer = URI.parse(item["url"]).host.to_s.delete_prefix("www.")
          middle_rating = item["relation"] == "external_assessment" &&
            ((reviewer == "mediabiasfactcheck.com" && item["quote"].match?(/\bleast biased\b/i)) ||
              (reviewer == "adfontesmedia.com" && item["quote"].match?(/\bmiddle(?: bias)?\b/i)))
          centrist || middle_rating
        end
        return unknown unless explicit
      end
      { "host" => host, "position" => raw["editorial_position"], "confidence" => "documented", "reason" => raw["editorial_reason"], "evidence" => citations }
    rescue TopicDiscovery::InvalidResponse, Timeout::Error
      unknown || { "host" => host, "position" => "unknown", "confidence" => "unknown", "reason" => "invalid_profile_response", "evidence" => [] }
    end
  end
end
