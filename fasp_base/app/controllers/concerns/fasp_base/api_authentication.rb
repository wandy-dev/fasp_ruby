module FaspBase
  module ApiAuthentication
    extend ActiveSupport::Concern

    DIGEST_PATTERN = /sha-256=:(.*?):/
    KEYID_PATTERN = /keyid="(.*?)"/

    included do
      attr_reader :current_server
      helper_method :current_user

      skip_forgery_protection

      before_action :require_authentication

      after_action :sign_response
    end

    private

    def current_server
      @current_server
    end

    def current_user
      @current_user ||= current_server.user
    end

    def require_authentication
      validate_content_digest!
      validate_signature!
    rescue Error, Linzer::Error, ActiveRecord::RecordNotFound => e
      logger.debug("Authentication error: #{e}")
      authentication_error
    end

    def authentication_error
      respond_to do |format|
        format.json { head :unauthorized }
      end
    end

    def validate_content_digest!
      content_digest_header = request.headers["content-digest"]
      raise Error, "content-digest missing" if content_digest_header.blank?

      digest_received = content_digest_header.match(DIGEST_PATTERN)[1]

      digest_computed = OpenSSL::Digest.base64digest("sha256", request.body&.string || "")

      raise Error, "content-digest does not match" if digest_received != digest_computed
    end

    def validate_signature!
      signature_input = request.headers["signature-input"]&.encode("UTF-8")
      raise Error, "signature-input is missing" if signature_input.blank?

      keyid = signature_input.match(KEYID_PATTERN)[1]
      server = Server.find(keyid)
      linzer_request = Linzer.new_request(
        request.method,
        request.original_url,
        {},
        {
          "content-digest" => request.headers["content-digest"],
          "signature-input" => signature_input,
          "signature" => request.headers["signature"]
        }
      )
      message = Linzer::Message.new(linzer_request)
      key = Linzer.new_ed25519_public_key(server.public_key_pem, keyid)
      signature = Linzer::Signature.build(message.headers)
      Linzer.verify(key, message, signature)
      @current_server = server
    end

    def sign_response
      response.headers["content-digest"] = "sha-256=:#{OpenSSL::Digest.base64digest("sha256", response.body || "")}:"

      linzer_response = Linzer.new_response(response.body, response.status, { "content-digest" => response.headers["content-digest"] })
      message = Linzer::Message.new(linzer_response)
      key = Linzer.new_ed25519_key(current_server.fasp_private_key_pem)
      signature = Linzer.sign(key, message, %w[@status content-digest])

      response.headers.merge!(signature.to_h)
    end
  end
end
