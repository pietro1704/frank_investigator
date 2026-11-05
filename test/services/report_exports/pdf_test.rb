require "test_helper"
require "tempfile"
require "shellwords"

class ReportExports::PdfTest < ActiveSupport::TestCase
  test "a real cold browser can start within the overall export deadline" do
    previous_path = ENV["CHROMIUM_PATH"]
    binary = previous_path.presence || ENV["BROWSER_PATH"].presence || Ferrum::Browser::Options::Chrome.options.detect_path
    assert binary.present?, "A prebuilt Chromium is required for the PDF runtime regression"
    root = Rails.root.join("test/fixtures/files/topic_assessment")
    discovery = JSON.parse(File.read(root.join("input.json")))
    topic = TopicInvestigation.create!(question: discovery["question"], analysis_mode: :brief, status: :completed,
      discovery:, report: JSON.parse(File.read(root.join("report.json"))), finished_at: Time.current)
    document = ReportExports::Document.new(record: topic, report_url: "https://frank.example/topic_investigations/#{topic.slug}")
    Tempfile.create([ "pdf-cold-start", ".sh" ]) do |launcher|
      launcher.write("#!/bin/sh\nsleep 11\nexec #{Shellwords.escape(binary)} \"$@\"\n")
      launcher.flush
      File.chmod(0o755, launcher.path)
      path = launcher.path
      launcher.close # Linux cannot execute a launcher still open for writing (ETXTBSY).
      ENV["CHROMIUM_PATH"] = path
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        data = ReportExports::Pdf.call(document)
      rescue ReportExports::Pdf::Unavailable => error
        flunk "Cold-start PDF unavailable: #{error.cause&.class}: #{error.cause&.message}"
      end
      assert data.start_with?("%PDF-")
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 30
      refute ReportExports::Pdf::LOCK.locked?
    end
  ensure
    ENV["CHROMIUM_PATH"] = previous_path
  end

  test "browser timeouts stop generation cleanly without holding the render lock" do
    original = Ferrum::Browser.method(:new)
    Ferrum::Browser.define_singleton_method(:new) { |**| raise Ferrum::TimeoutError }
    assert_raises(ReportExports::Pdf::Unavailable) { ReportExports::Pdf.call(nil) }
    refute ReportExports::Pdf::LOCK.locked?
  ensure
    Ferrum::Browser.define_singleton_method(:new, original) if original
  end
end
