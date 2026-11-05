require "ferrum"
require "timeout"

module ReportExports
  class Pdf
    class Unavailable < StandardError; end
    LOCK = Mutex.new

    def self.call(document)
      raise Unavailable unless LOCK.try_lock
      browser = nil
      begin
        Timeout.timeout(30) do
          browser = Ferrum::Browser.new(headless: true, timeout: 15, process_timeout: 10,
            browser_path: ENV["CHROMIUM_PATH"].presence || ENV["BROWSER_PATH"].presence,
            browser_options: { "no-sandbox" => nil, "disable-dev-shm-usage" => nil })
          browser.network.intercept
          browser.on(:request) { |request| request.abort }
          browser.page.command("Emulation.setScriptExecutionDisabled", value: true)
          browser.page.content = Html.new(document).book
          data = browser.pdf(format: :A4, encoding: :binary, print_background: true, prefer_css_page_size: true,
            display_header_footer: true, header_template: "<span></span>",
            footer_template: '<div style="font-size:9px;text-align:center;width:100%;color:#667085">Frank Investigator · <span class="pageNumber"></span> / <span class="totalPages"></span></div>')
          raise Unavailable unless data.start_with?("%PDF-")
          data
        end
      rescue Ferrum::Error, Timeout::Error, SystemCallError => error
        Rails.logger.warn("Report PDF unavailable (#{error.class.name})")
        raise Unavailable
      ensure
        begin
          browser&.quit
        rescue Ferrum::Error, SystemCallError => error
          Rails.logger.warn("Report PDF cleanup failed (#{error.class.name})")
        ensure
          LOCK.unlock
        end
      end
    end
  end
end
