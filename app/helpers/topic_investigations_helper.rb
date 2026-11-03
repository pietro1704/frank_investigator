module TopicInvestigationsHelper
  def topic_source_url(value)
    uri = URI.parse(value.to_s)
    value if %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil?
  rescue URI::InvalidURIError
    nil
  end
  def topic_profile_checked_at(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end
end
