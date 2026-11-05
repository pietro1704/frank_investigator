require "test_helper"

class ReportExports::PdfTest < ActiveSupport::TestCase
  test "browser timeouts stop generation cleanly without holding the render lock" do
    original = Ferrum::Browser.method(:new)
    Ferrum::Browser.define_singleton_method(:new) { |**| raise Ferrum::TimeoutError }
    assert_raises(ReportExports::Pdf::Unavailable) { ReportExports::Pdf.call(nil) }
    refute ReportExports::Pdf::LOCK.locked?
  ensure
    Ferrum::Browser.define_singleton_method(:new, original) if original
  end
end
