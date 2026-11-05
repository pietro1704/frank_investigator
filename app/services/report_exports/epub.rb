require "zip"

module ReportExports
  class Epub
    def self.call(document)
      html = Html.new(document)
      entries = {
        "META-INF/container.xml" => '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        "EPUB/package.opf" => package(document),
        "EPUB/style.css" => Html::CSS.read,
        "EPUB/cover.xhtml" => html.page(title: document.title, content: html.cover),
        "EPUB/nav.xhtml" => html.page(title: I18n.t("report_exports.contents"), content: html.navigation(epub: true))
      }
      document.sections.each do |section|
        entries["EPUB/#{section.id}.xhtml"] = html.page(title: section.title, content: html.chapter(section))
      end
      Zip::OutputStream.write_buffer do |zip|
        # A known size prevents rubyzip from reserving a ZIP64 extra field,
        # forbidden on EPUB mimetype entries. Do not change global ZIP options.
        mimetype = Zip::Entry.new("", "mimetype")
        mimetype.compression_method = Zip::Entry::STORED
        mimetype.size = "application/epub+zip".bytesize
        zip.put_next_entry(mimetype)
        zip.write("application/epub+zip")
        entries.each { |name, content| zip.put_next_entry(name); zip.write(content) }
      end.string
    end

    def self.package(document)
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.package("xmlns" => "http://www.idpf.org/2007/opf", "version" => "3.0", "unique-identifier" => "book-id") do
          xml.metadata("xmlns:dc" => "http://purl.org/dc/elements/1.1/") do
            xml["dc"].identifier(document.identifier, id: "book-id")
            xml["dc"].title(document.title)
            xml["dc"].language(I18n.locale.to_s)
            xml["dc"].creator("Frank Investigator")
            xml["dc"].source(document.report_url)
            xml.meta(document.record.updated_at.utc.strftime("%Y-%m-%dT%H:%M:%SZ"), property: "dcterms:modified")
          end
          xml.manifest do
            xml.item(id: "style", href: "style.css", "media-type" => "text/css")
            xml.item(id: "nav", href: "nav.xhtml", "media-type" => "application/xhtml+xml", properties: "nav")
            xml.item(id: "cover", href: "cover.xhtml", "media-type" => "application/xhtml+xml")
            document.sections.each { |section| xml.item(id: section.id, href: "#{section.id}.xhtml", "media-type" => "application/xhtml+xml") }
          end
          xml.spine do
            xml.itemref(idref: "cover")
            document.sections.each { |section| xml.itemref(idref: section.id) }
          end
        end
      end.to_xml
    end
    private_class_method :package
  end
end
