require "socket"
require "digest"

module Llm
  module Chatgpt
    class Login
      SCOPES = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct".freeze
      attr_reader :state, :redirect_uri

      def initialize(credentials: Credentials.new, redirect_uri:)
        @credentials = credentials
        @redirect_uri = redirect_uri
        @previous = credentials.read
        @state = SecureRandom.urlsafe_base64(32)
        @nonce = SecureRandom.urlsafe_base64(32)
        @verifier = SecureRandom.urlsafe_base64(64)
      end

      def authorization_url
        params = {
          client_id: @previous["client_id"].presence || "dynamic_agent_client",
          ext_agent_host_id: @credentials.host_id,
          response_type: "code", redirect_uri:, scope: SCOPES,
          resource: "https://api.openai.com/v1", state:, nonce: @nonce,
          code_challenge_method: "S256", code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
        }
        params[:agent_name_hint] = "Frank Investigator" unless @previous["client_id"].present?
        "https://auth.openai.com/api/accounts/authorize?#{URI.encode_www_form(params)}"
      end

      def complete(params)
        raise Error.new("invalid_oauth_state") unless ActiveSupport::SecurityUtils.secure_compare(state, params["state"].to_s)
        raise Error.new("authorization_cancelled") if params["error"].present?
        previous_client = @previous["client_id"]
        issued_client = params["client_id"].presence || previous_client
        unless issued_client.present? && issued_client != "dynamic_agent_client" && (previous_client.blank? || issued_client == previous_client)
          raise Error.new("client_identity_mismatch")
        end
        raise Error.new("missing_authorization_code") if params["code"].blank?
        tokens = Transport.new.json("https://auth.openai.com/api/accounts/oauth/token", form: {
          grant_type: "authorization_code", client_id: issued_client, code: params.fetch("code"),
          code_verifier: @verifier, redirect_uri:, resource: "https://api.openai.com/v1"
        })
        identity = Identity.verify(tokens["id_token"], client_id: issued_client, nonce: @nonce, subject: @previous["subject"])
        data = @credentials.replace_tokens({
          "client_id" => issued_client, "subject" => identity.fetch("sub"), "issuer" => identity.fetch("iss"),
          "email" => identity["email"], "ext_agent_host_id" => @credentials.host_id, "scopes" => []
        }, tokens)
        @credentials.locked do
          # Do not replace a different registration created while the browser was open.
          current = @credentials.read
          if (current["subject"].present? && current["subject"] != data["subject"]) ||
              (current["client_id"].present? && current["client_id"] != data["client_id"])
            raise Error.new("account_changed_during_sign_in")
          end
          @credentials.write(data)
        end
        data
      rescue Error => error
        # An expired one-time code must not cause a second dynamic registration.
        if error.code == "invalid_grant" && @previous["client_id"].blank? && issued_client.present?
          @credentials.locked do
            if @credentials.read.empty?
              @credentials.write({ "client_id" => issued_client, "ext_agent_host_id" => @credentials.host_id })
            end
          end
        end
        raise
      end

      def self.run(credentials: Credentials.new, timeout: 600)
        TCPServer.open("127.0.0.1", 0) do |server|
          login = new(credentials:, redirect_uri: "http://127.0.0.1:#{server.addr[1]}/auth/callback")
          url = login.authorization_url
          puts I18n.t("chatgpt.continue", account: credentials.account)
          puts url
          open_browser(url)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          loop do
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise Error.new("sign_in_timed_out") if remaining <= 0 || !IO.select([ server ], nil, nil, remaining)
            socket = server.accept
            begin
              request = Timeout.timeout(5) do
                line = socket.gets(8192)
                size = line.to_s.bytesize
                while (header = socket.gets(8192)) && header != "\r\n" && header != "\n"
                  size += header.bytesize
                  raise Error.new("invalid_callback_request") if size > 16384
                end
                line
              end
              method, target = request.to_s.split(" ", 3)
              uri = URI(target.to_s)
              unless method == "GET" && uri.path == "/auth/callback"
                socket.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                next
              end
              data = login.complete(URI.decode_www_form(uri.query.to_s).to_h)
              permitted = data.fetch("scopes").include?(Credentials::PLAN_SCOPE)
              message = I18n.t(permitted ? "chatgpt.connected_browser" : "chatgpt.denied_browser")
              socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: #{message.bytesize}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n#{message}")
              return data
            rescue Error
              socket.write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") rescue nil
              raise
            ensure
              socket.close
            end
          end
        end
      end

      def self.open_browser(url)
        if RUBY_PLATFORM.include?("darwin")
          system("open", url)
        elsif ENV["DISPLAY"].present?
          system("xdg-open", url)
        end
      end
    end
  end
end
