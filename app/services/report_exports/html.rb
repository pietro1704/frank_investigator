require "nokogiri"

module ReportExports
  class Html
    TAGS = %w[section article div h2 h3 h4 h5 h6 p blockquote ul ol li dl dt dd strong em span br a].freeze
    CSS = Rails.root.join("app/views/report_exports/book.css")

    def self.safe_url(value, base_url: nil)
      return nil if value.blank?
      uri = base_url ? URI.join(base_url, value.to_s) : URI.parse(value.to_s)
      uri.to_s if uri.scheme.in?(%w[http https]) && uri.host.present? && uri.userinfo.nil?
    rescue URI::InvalidURIError
      nil
    end

    def self.clean(html, base_url:)
      fragment = Nokogiri::HTML5.fragment(html)
      fragment.css("script, style, form, button, input, svg, canvas, iframe, object, img, audio, video, .popover-content").remove
      fragment.css("details").each { |node| node.replace(node.children) }
      fragment.css("summary").each do |node|
        node.name = node.css("div, p, ul, ol, dl, section, article").any? ? "div" : "h4"
      end
      safe = Rails::HTML5::SafeListSanitizer.new.sanitize(fragment.to_html, tags: TAGS, attributes: %w[href])
      fragment = Nokogiri::HTML5.fragment(safe)
      fragment.css("a").each do |node|
        url = safe_url(node["href"], base_url:)
        url ? node["href"] = url : node.remove_attribute("href")
      end
      fragment.to_xhtml
    end

    def initialize(document)
      @document = document
    end

    def page(title:, content:, inline_css: false)
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.html("xmlns" => "http://www.w3.org/1999/xhtml", "xmlns:epub" => "http://www.idpf.org/2007/ops",
          "lang" => I18n.locale.to_s, "xml:lang" => I18n.locale.to_s) do
          xml.head do
            xml.title(title)
            xml.meta("http-equiv" => "Content-Security-Policy", "content" => "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'") if inline_css
            inline_css ? xml.style(CSS.read) : xml.link("rel" => "stylesheet", "type" => "text/css", "href" => "style.css")
          end
          xml.body { xml << content }
        end
      end.to_xml
    end

    def cover
      fragment do |xml|
        xml.header("class" => "cover") do
          xml.p("Frank Investigator", "class" => "brand")
          if @document.record.is_a?(TopicInvestigation)
            xml.h1(I18n.t("report_exports.topic_title"))
            xml.p(@document.title, "class" => "question")
          else
            xml.h1(@document.title)
          end
          xml.p(I18n.t("report_exports.date", date: I18n.l(@document.date, format: :long)))
          xml.p(@document.notice, "class" => "notice") if @document.notice
          xml.p(I18n.t("report_exports.scope"))
          xml.p { xml.a(I18n.t("report_exports.online_report"), href: self.class.safe_url(@document.report_url)) }
          xml.p(@document.report_url, "class" => "source-url")
        end
      end
    end

    def navigation(epub:)
      fragment do |xml|
        xml.nav("epub:type" => "toc", "id" => "toc", "class" => "contents") do
          xml.h1(I18n.t("report_exports.contents"))
          xml.ol do
            @document.sections.each do |section|
              href = epub ? "#{section.id}.xhtml" : "##{section.id}"
              xml.li { xml.a(section.title, href:) }
            end
          end
        end
      end
    end

    def chapter(section)
      fragment do |xml|
        xml.section("id" => section.id, "class" => "chapter") do
          xml.h1(section.title)
          xml << section.html
        end
      end
    end

    def book
      content = cover + navigation(epub: false) + @document.sections.map { |section| chapter(section) }.join
      page(title: @document.title, content:, inline_css: true)
    end

    private

    def fragment
      # The wrapper supplies namespaces for epub:type while fragments are built.
      builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.div("xmlns:epub" => "http://www.idpf.org/2007/ops") { yield xml }
      end
      builder.doc.root.children.map(&:to_xml).join
    end
  end
end
