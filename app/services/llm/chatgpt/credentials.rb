require "tempfile"
require "securerandom"

module Llm
  module Chatgpt
    class Credentials
      PLAN_SCOPE = "chatgpt.tokens.use.direct".freeze
      TERMINAL_REFRESH_ERRORS = %w[invalid_grant invalid_refresh_token token_expired refresh_token_expired refresh_token_invalidated refresh_token_reused].freeze
      attr_reader :path, :account

      def initialize(directory: Rails.root.join("storage/chatgpt"), account: ENV.fetch("FRANK_INVESTIGATOR_CHATGPT_ACCOUNT", "main"))
        raise ArgumentError, "Invalid account label" unless account.match?(/\A[a-zA-Z0-9_-]{1,64}\z/)
        @directory = Pathname.new(directory)
        @account = account
        @path = @directory.join("#{account}.json")
      end

      def available?
        data = read
        !data["usage_paused"] && data["client_id"].present? && data["subject"].present? && Array(data["scopes"]).include?(PLAN_SCOPE) &&
          ((data["access_token"].present? && data["expires_at"].to_i > Time.now.to_i + 60) || data["refresh_token"].present?)
      rescue Error
        false
      end

      def read
        return {} unless path.exist?
        JSON.parse(path.read)
      rescue JSON::ParserError
        raise Error.new("invalid_credentials_file")
      end

      def write(data)
        FileUtils.mkdir_p(@directory, mode: 0o700)
        Tempfile.create([ ".credentials-", ".json" ], @directory) do |file|
          file.chmod(0o600)
          file.write(JSON.generate(data))
          file.flush
          file.fsync
          File.rename(file.path, path)
        end
      end

      def locked
        FileUtils.mkdir_p(@directory, mode: 0o700)
        File.open(@directory.join("#{account}.lock"), File::RDWR | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          yield
        ensure
          file.flock(File::LOCK_UN)
        end
      end

      def host_id
        FileUtils.mkdir_p(@directory, mode: 0o700)
        File.open(@directory.join("host-id"), File::RDWR | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          id = file.read.strip
          if id.empty?
            id = "urn:uuid:#{SecureRandom.uuid}"
            file.write(id)
            file.flush
          end
          id
        end
      end

      def access_token
        locked do
          data = read
          raise Error.new("subscription_sharing_usage_limit_exceeded") if data["usage_paused"]
          raise Error.new("sign_in_required") unless available?
          if data["expires_at"].to_i <= Time.now.to_i + 60
            tokens = Transport.new.json("https://auth.openai.com/api/accounts/oauth/token", form: {
              grant_type: "refresh_token", client_id: data.fetch("client_id"),
              refresh_token: data.fetch("refresh_token"), resource: "https://api.openai.com/v1"
            })
            if tokens["id_token"].present?
              Identity.verify(tokens["id_token"], client_id: data.fetch("client_id"), subject: data.fetch("subject"))
            end
            data = replace_tokens(data, tokens)
            write(data)
          end
          raise Error.new("plan_permission_required") unless data.fetch("scopes").include?(PLAN_SCOPE)
          data.fetch("access_token")
        rescue Error => error
          write(data.except("access_token", "refresh_token", "id_token", "expires_at", "scopes")) if TERMINAL_REFRESH_ERRORS.include?(error.code)
          raise
        end
      end

      def pause_usage(access_token)
        locked do
          data = read
          write(data.merge("usage_paused" => true)) if data["access_token"] == access_token
        end
      end

      def resume_usage
        locked { write(read.except("usage_paused")) }
      end

      def replace_tokens(data, tokens)
        raise Error.new("invalid_token_response") if tokens["access_token"].blank? || tokens["expires_in"].to_i <= 0
        result = data.merge(tokens.slice("access_token", "refresh_token", "id_token", "token_type"))
        result["scopes"] = tokens["scope"].split if tokens.key?("scope")
        result["expires_at"] = Time.now.to_i + tokens.fetch("expires_in").to_i
        result
      end

      def sign_out
        locked do
          data = read
          confirmed = false
          begin
            if data["refresh_token"].present?
              discovery = Transport.new.json("https://auth.openai.com/.well-known/openid-configuration")
              # Discovery may change; credentials only go back to OpenAI's issuer.
              endpoint = URI(discovery.fetch("revocation_endpoint"))
              raise Error.new("invalid_revocation_endpoint") unless endpoint.scheme == "https" && endpoint.host == "auth.openai.com"
              Transport.new.json(endpoint.to_s, form: { token: data.fetch("refresh_token"), token_type_hint: "refresh_token", client_id: data.fetch("client_id") })
              confirmed = true
            end
          rescue StandardError
            confirmed = false
          ensure
            write(data.except("access_token", "refresh_token", "id_token", "expires_at", "scopes", "usage_paused"))
          end
          confirmed
        end
      end
    end
  end
end
