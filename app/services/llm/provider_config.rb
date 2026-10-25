module Llm
  module ProviderConfig
    extend self

    OPENROUTER_DEFAULT_MODELS = "openai/gpt-5-mini,anthropic/claude-sonnet-4-6,google/gemini-2.5-pro".freeze
    OPENAI_DEFAULT_MODELS = "gpt-5-mini".freeze
    KNOWN_PROVIDERS = %w[openrouter openai chatgpt].freeze

    def provider
      raw = Rails.configuration.x.frank_investigator.llm_provider.to_s.presence || "openrouter"
      unless KNOWN_PROVIDERS.include?(raw)
        Rails.logger.warn("[ProviderConfig] Unrecognized LLM provider #{raw.inspect}, falling back to openrouter")
        return "openrouter"
      end
      raw
    end

    def models
      Array(Rails.configuration.x.frank_investigator.llm_models).reject(&:blank?)
    end

    def available?
      return Chatgpt::Credentials.new.available? && models.any? if provider == "chatgpt"
      defined?(RubyLLM) && api_key_present? && models.any?
    end

    def api_key_present?
      return Chatgpt::Credentials.new.available? if provider == "chatgpt"
      ENV[api_key_env].present?
    end

    def api_key_env
      case provider
      when "chatgpt"
        "FRANK_INVESTIGATOR_CHATGPT_ACCOUNT"
      when "openai"
        "OPENAI_API_KEY"
      else
        "OPENROUTER_API_KEY"
      end
    end

    def default_models_for(selected_provider)
      case selected_provider.to_s
      when "chatgpt"
        "gpt-6.1-sol"
      when "openai"
        OPENAI_DEFAULT_MODELS
      else
        OPENROUTER_DEFAULT_MODELS
      end
    end

    def provider_symbol
      provider.to_sym
    end

    def assume_model_exists?
      provider.present?
    end

    def chat(model:)
      return Chatgpt::Chat.new(model:) if provider == "chatgpt"
      RubyLLM.chat(
        model:,
        provider: provider_symbol,
        assume_model_exists: assume_model_exists?
      )
    end
  end
end
