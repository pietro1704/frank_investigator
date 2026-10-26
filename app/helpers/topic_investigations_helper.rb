module TopicInvestigationsHelper
  def topic_source_url(value)
    uri = URI.parse(value.to_s)
    value if %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil?
  rescue URI::InvalidURIError
    nil
  end
end
