Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :data, :https
    policy.object_src  :none
    policy.script_src  :self
    policy.style_src   :self
    policy.connect_src :self

    if ENV["GOOGLE_ANALYTICS_ID"].present?
      policy.script_src  :self, "https://www.googletagmanager.com"
      policy.connect_src :self, "https://www.google-analytics.com", "https://www.googletagmanager.com"
    end

    if Rails.env.development?
      policy.connect_src :self, "ws://localhost:*", "wss://localhost:*"
    else
      policy.connect_src :self, :wss
    end
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
