namespace :frank do
  namespace :chatgpt do
    desc "Connect a local ChatGPT account using the official sign-in flow (ACCOUNT=main)"
    task login: :environment do
      credentials = Llm::Chatgpt::Credentials.new(account: ENV.fetch("ACCOUNT", ENV.fetch("FRANK_INVESTIGATOR_CHATGPT_ACCOUNT", "main")))
      data = Llm::Chatgpt::Login.run(credentials:)
      puts I18n.t("chatgpt.account", account: credentials.account, email: data["email"], client_id: data.fetch("client_id"))
      puts I18n.t("chatgpt.permission", status: I18n.t(data.fetch("scopes").include?(Llm::Chatgpt::Credentials::PLAN_SCOPE) ? "chatgpt.enabled" : "chatgpt.not_granted"))
      puts I18n.t("chatgpt.usage")
    rescue Llm::Chatgpt::Error => error
      abort error.message
    end

    desc "Show local ChatGPT registrations and the selected account"
    task status: :environment do
      selected = ENV.fetch("FRANK_INVESTIGATOR_CHATGPT_ACCOUNT", "main")
      Dir.glob(Rails.root.join("storage/chatgpt/*.json")).sort.each do |path|
        credentials = Llm::Chatgpt::Credentials.new(account: File.basename(path, ".json"))
        data = credentials.read
        status = data["usage_paused"] ? "chatgpt.usage_paused" : (credentials.available? ? "chatgpt.connected" : "chatgpt.not_connected")
        puts I18n.t("chatgpt.status", selected: credentials.account == selected ? "*" : " ", account: credentials.account, email: data["email"], client_id: data["client_id"], status: I18n.t(status))
      end
      puts I18n.t("chatgpt.usage")
    end

    desc "Resume ChatGPT plan requests after reviewing the plan's usage limit (ACCOUNT=main)"
    task resume: :environment do
      credentials = Llm::Chatgpt::Credentials.new(account: ENV.fetch("ACCOUNT", ENV.fetch("FRANK_INVESTIGATOR_CHATGPT_ACCOUNT", "main")))
      credentials.resume_usage
      puts I18n.t("chatgpt.usage_resumed")
      puts I18n.t("chatgpt.usage")
    end

    desc "List models available to the selected ChatGPT account"
    task models: :environment do
      credentials = Llm::Chatgpt::Credentials.new
      data = Llm::Chatgpt::Transport.new.json("https://api.openai.com/v1/models", bearer: credentials.access_token)
      data.fetch("models").select { |model| model["visibility"] == "list" }.each do |model|
        puts "#{model.fetch('slug')}\t#{model.fetch('display_name')}"
      end
    end

    desc "Sign out a local ChatGPT account, attempting server-side revocation (ACCOUNT=main)"
    task logout: :environment do
      credentials = Llm::Chatgpt::Credentials.new(account: ENV.fetch("ACCOUNT", ENV.fetch("FRANK_INVESTIGATOR_CHATGPT_ACCOUNT", "main")))
      confirmed = credentials.sign_out
      puts I18n.t("chatgpt.signed_out", result: I18n.t(confirmed ? "chatgpt.revoked" : "chatgpt.revocation_unconfirmed"))
    end
  end
end
