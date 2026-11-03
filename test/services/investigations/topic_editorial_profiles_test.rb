require "test_helper"

class Investigations::TopicEditorialProfilesTest < ActiveSupport::TestCase
  setup do
    @raw = JSON.parse(file_fixture("topic_discovery/editorial_profile.json").read)
    @model = Object.new
    raw = @raw
    @model.define_singleton_method(:editorial_profile) { |**| raw.deep_dup }
    @pages = {}
    pages = @pages
    @fetcher = Object.new
    @fetcher.define_singleton_method(:call) do |url|
      Fetchers::ChromiumFetcher::Snapshot.new(html: pages.fetch(url) { raise Fetchers::ChromiumFetcher::FetchError }, title: "Publisher profile")
    end
  end

  def article(id = "S1", host = "publication.example.org")
    { "id" => id, "url" => "https://#{host}/news", "title" => id, "body" => "Unique reporting #{id} " * 50,
      "kind" => "news_article", "editorial_position" => "unknown", "editorial_confidence" => "unknown", "publisher_pages" => [ "https://#{host}/about" ] }
  end

  def page(title, body, link: "")
    "<html><title>#{title}</title><body><article><p>#{body}</p>#{link}</article></body></html>"
  end

  test "live-observed profile schema grounds a publication label outside its news body" do
    document = article
    quote = @raw["evidence"].sole["quote"]
    @pages[document["publisher_pages"].sole] = page("About publication", quote + " The publication describes its own editorial perspective and audience. " * 10)
    resolver = Investigations::TopicEditorialProfiles.new(model: @model, fetcher: @fetcher)
    resolver.enrich(document)
    assert_equal "left", document["editorial_position"]
    assert_equal "documented", document["editorial_confidence"]
    refute_includes document["body"], quote
    assert_equal quote, document.dig("editorial_profile", "evidence").sole["quote"]
    assert document.dig("editorial_profile", "evidence").sole["body_digest"].present?
  end

  test "hints do not classify a publication when its documentary evidence is unavailable" do
    document = article("S1", "reuters.com")
    @fetcher.define_singleton_method(:call) { |*| raise Fetchers::ChromiumFetcher::FetchError }
    resolver = Investigations::TopicEditorialProfiles.new(model: @model, fetcher: @fetcher)
    resolver.enrich(document)
    assert_equal "unknown", document["editorial_position"]
    assert_equal "unknown", resolver.profiles["reuters.com"]["confidence"]
  end

  test "invented profile quotations and unrelated external profiles never fill quotas" do
    document = article
    @pages[document["publisher_pages"].sole] = page("About publication", "A description that does not contain the asserted classification quotation. " * 10)
    resolver = Investigations::TopicEditorialProfiles.new(model: @model, fetcher: @fetcher)
    resolver.enrich(document)
    assert_equal "unknown", document["editorial_position"]
    reuters = article("S2", "reuters.com").merge("publisher_pages" => [])
    @pages["https://www.allsides.com/news-source/reuters-media-bias"] = page("Other outlet profile", @raw["evidence"].sole["quote"] * 10)
    resolver.enrich(reuters)
    assert_equal "unknown", reuters["editorial_position"]
  end

  test "impartiality alone cannot be promoted to a documented centrist classification" do
    document = article
    quote = "Our publication is independent and reports impartially without a party affiliation."
    @pages[document["publisher_pages"].sole] = page("About publication", quote * 6)
    @raw.merge!("editorial_position" => "center", "evidence" => [ { "source_id" => "P1", "quote" => quote } ])
    resolver = Investigations::TopicEditorialProfiles.new(model: @model, fetcher: @fetcher)
    resolver.enrich(document)
    assert_equal "unknown", document["editorial_position"]
  end

  test "an identified external political-bias rating can document the middle bucket" do
    document = article("S1", "reuters.com").merge("publisher_pages" => [])
    quote = "The publication is explicitly classified Least Biased on the political-bias scale."
    @pages["https://mediabiasfactcheck.com/reuters/"] = page("Reuters profile", quote * 5, link: '<a href="https://www.reuters.com">Publication</a>')
    @raw.merge!("editorial_position" => "center", "evidence" => [ { "source_id" => "P1", "quote" => quote } ])
    resolver = Investigations::TopicEditorialProfiles.new(model: @model, fetcher: @fetcher)
    resolver.enrich(document)
    assert_equal "center", document["editorial_position"]
    assert_equal "external_assessment", document.dig("editorial_profile", "evidence").sole["relation"]
  end

  test "profile checks cache by publisher and have a fixed publisher limit" do
    @fetcher.define_singleton_method(:call) { |*| raise Fetchers::ChromiumFetcher::FetchError }
    resolver = Investigations::TopicEditorialProfiles.new(model: @model, fetcher: @fetcher)
    12.times { |i| resolver.enrich(article("S#{i}", "outlet#{i}.example.org")) }
    assert_equal 8, resolver.profiles.size
  end

  test "external profiles identify publications whose names differ from their domain" do
    document = article("S1", "csmonitor.com").merge("publisher_pages" => [])
    quote = "The publication is explicitly classified Least Biased on the political-bias scale."
    @pages["https://mediabiasfactcheck.com/christian-science-monitor/"] = page("Christian Science Monitor profile", quote * 5, link: '<a href="https://www.csmonitor.com">Publication</a>')
    @raw.merge!("editorial_position" => "center", "evidence" => [ { "source_id" => "P1", "quote" => quote } ])
    resolver = Investigations::TopicEditorialProfiles.new(model: @model, fetcher: @fetcher)
    resolver.enrich(document)
    assert_equal "center", document["editorial_position"]
  end

  test "six independent publishers with literal profile evidence satisfy the requested quotas" do
    documents = []
    @model.define_singleton_method(:editorial_profile) do |publication:, documents:|
      side = publication["host"].split(".").first.sub(/\d+$/, "")
      { "editorial_position" => side, "editorial_confidence" => "documented", "editorial_reason" => "The publication explicitly identifies its editorial position in its own profile.",
        "evidence" => [ { "source_id" => documents.first["id"], "quote" => "Our publication explicitly identifies its political editorial position as #{side}." } ] }
    end
    resolver = Investigations::TopicEditorialProfiles.new(model: @model, fetcher: @fetcher)
    %w[left center right].each do |side|
      2.times do |i|
        document = article("S#{documents.size + 1}", "#{side}#{i}.example.org")
        document["body"] = "#{side}#{i}uniqueword " * 70
        quote = "Our publication explicitly identifies its political editorial position as #{side}."
        @pages[document["publisher_pages"].sole] = page("Publication profile", quote + " We explain this editorial perspective to our readers. " * 10)
        resolver.enrich(document)
        documents << document
      end
    end
    selected = Investigations::TopicSourceSelection.call(documents: documents, relevant_ids: documents.pluck("id"), editorial_counts: { "left" => 2, "center" => 2, "right" => 2 })
    assert selected["coverage_complete"]
    assert_equal 6, selected["news_ids"].size
    assert documents.all? { |item| item.dig("editorial_profile", "evidence").present? }
  end

  test "publication aliases share one identity and do not manufacture independent editorial voices" do
    assert_equal "bbc.com", Investigations::TopicEditorialProfiles.publisher_key("www.bbc.co.uk")
    assert_equal "bbc.com", Investigations::TopicEditorialProfiles.publisher_key("bbc.com")
    refute_equal "bbc.com", Investigations::TopicEditorialProfiles.publisher_key("bbc.com.evil.example.org")
  end

  test "directed queries keep requested perspectives within the eight-query budget" do
    plan = JSON.parse(file_fixture("topic_discovery/structured_plan.json").read)
    plan["news_queries"] = [ "consulta em português", "international query preserving the requested scope" ]
    queries = Investigations::TopicEditorialProfiles.queries(plan)
    assert_operator queries.size, :<=, 8
    assert_includes queries, "international query preserving the requested scope site:reuters.com"
    assert queries.any? { |query| query.include?("site:brasildefato.com.br") }
    assert queries.any? { |query| query.include?("site:revistaoeste.com") }
  end
end
