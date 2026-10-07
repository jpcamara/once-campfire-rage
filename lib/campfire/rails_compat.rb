# The message formats Rails writes and reads, so cookies, avatar tokens and Turbo stream names
# stay interchangeable with the Rails app (same SECRET_KEY_BASE).
require "openssl"
require "base64"
require "json"
require "time"

module Campfire
  module RailsCompat
    # Rails::Application#key_generator: PBKDF2-HMAC-SHA256, 1000 iterations.
    class KeyGenerator
      def initialize(secret)
        @secret = secret
        @keys = {}
      end

      def generate_key(salt, length = 64)
        @keys[[ salt, length ]] ||= OpenSSL::PKCS5.pbkdf2_hmac(@secret, salt, 1000, length, OpenSSL::Digest.new("SHA256"))
      end
    end

    # ActiveSupport::MessageVerifier, for the three shapes Campfire uses:
    #   :envelope_message  signed cookies: {"_rails":{"message":base64(json),"exp":..,"pur":..}}, strict Base64, SHA1
    #   :envelope_data     signed ids: {"_rails":{"data":value,"pur":..}}, URL-safe Base64 without padding, SHA256
    #   :bare              Turbo stream names: base64(json), strict Base64, SHA256
    class MessageVerifier
      def initialize(secret, digest:, format:, url_safe: format == :envelope_data, padding: false)
        @secret, @digest, @format, @url_safe, @padding = secret, digest, format, url_safe, padding
      end

      def generate(value, purpose: nil, expires_at: nil)
        data = encode(JSON.generate(payload_for(value, purpose, expires_at)))
        "#{data}--#{sign(data)}"
      end

      def verify(signed, purpose: nil, now: Time.now)
        return nil unless signed.is_a?(String)
        data, digest = signed.split("--", 2)
        return nil if data.nil? || digest.nil? || digest.include?("--")
        expected = sign(data)
        return nil unless digest.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(digest, expected)

        unwrap(JSON.parse(decode(data)), purpose, now)
      rescue JSON::ParserError, ArgumentError
        nil
      end

      private
        def payload_for(value, purpose, expires_at)
          case @format
          when :bare then value
          when :envelope_data then { "_rails" => metadata({ "data" => value }, purpose, expires_at) }
          else { "_rails" => metadata({ "message" => Base64.strict_encode64(value), "exp" => expires_at && iso_ms(expires_at), "pur" => purpose }, nil, nil) }
          end
        end

        def metadata(hash, purpose, expires_at)
          hash["exp"] = iso_ms(expires_at) if expires_at
          hash["pur"] = purpose if purpose
          hash
        end

        def unwrap(parsed, purpose, now)
          return parsed if @format == :bare

          envelope = parsed.is_a?(Hash) && parsed["_rails"]
          return nil unless envelope.is_a?(Hash)
          return nil unless envelope["pur"] == purpose
          return nil if envelope["exp"] && Time.iso8601(envelope["exp"]) <= now

          if @format == :envelope_data
            envelope["data"]
          else
            message = envelope["message"]
            message && Base64.strict_decode64(message)
          end
        end

        def sign(data)
          OpenSSL::HMAC.hexdigest(@digest, @secret, data)
        end

        def encode(json)
          @url_safe ? Base64.urlsafe_encode64(json, padding: @padding) : Base64.strict_encode64(json)
        end

        def decode(data)
          @url_safe ? Base64.urlsafe_decode64(data) : Base64.strict_decode64(data)
        end

        def iso_ms(time)
          time.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
        end
    end

    # ActiveSupport::MessageEncryptor with aes-256-gcm, as the encrypted cookie jar uses it.
    class MessageEncryptor
      def initialize(secret)
        @secret = secret
      end

      def encrypt(value, purpose:, expires_at:)
        envelope = { "_rails" => { "message" => Base64.strict_encode64(value), "exp" => expires_at && expires_at.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"), "pur" => purpose } }
        cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
        cipher.key = @secret
        iv = cipher.random_iv
        cipher.auth_data = ""
        ciphertext = cipher.update(JSON.generate(envelope)) + cipher.final
        [ ciphertext, iv, cipher.auth_tag ].map { Base64.strict_encode64(it) }.join("--")
      end

      def decrypt(message, purpose:, now: Time.now)
        ciphertext, iv, tag = message.to_s.split("--").map { Base64.strict_decode64(it) }
        return nil unless ciphertext && iv&.bytesize == 12 && tag&.bytesize == 16

        cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
        cipher.key = @secret
        cipher.iv = iv
        cipher.auth_tag = tag
        cipher.auth_data = ""
        envelope = JSON.parse(cipher.update(ciphertext) + cipher.final)["_rails"]
        return nil unless envelope.is_a?(Hash) && envelope["pur"] == purpose
        return nil if envelope["exp"] && Time.iso8601(envelope["exp"]) <= now

        Base64.strict_decode64(envelope["message"])
      rescue OpenSSL::Cipher::CipherError, ArgumentError, JSON::ParserError, TypeError
        nil
      end
    end

    class Secrets
      attr_reader :signed_cookies, :encrypted_cookies, :signed_ids, :turbo_streams

      def initialize(secret_key_base)
        keys = KeyGenerator.new(secret_key_base)
        @signed_cookies = MessageVerifier.new(keys.generate_key("signed cookie"), digest: "SHA1", format: :envelope_message)
        @encrypted_cookies = MessageEncryptor.new(keys.generate_key("authenticated encrypted cookie", 32))
        @signed_ids = MessageVerifier.new(keys.generate_key("active_record/signed_id"), digest: "SHA256", format: :envelope_data)
        @turbo_streams = MessageVerifier.new(keys.generate_key("turbo/signed_stream_verifier_key"), digest: "SHA256", format: :bare)
        @global_ids = MessageVerifier.new(keys.generate_key("signed_global_ids"), digest: "SHA1", format: :envelope_data, padding: true)
        @stream_names = {}
      end

      # cookies.signed.permanent[name] = value (the :json cookie serializer dumps the string first)
      def sign_cookie(name, value, expires_at)
        @signed_cookies.generate(JSON.generate(value), purpose: "cookie.#{name}", expires_at: expires_at)
      end

      def verify_cookie(name, raw)
        dumped = @signed_cookies.verify(raw, purpose: "cookie.#{name}")
        value = dumped && JSON.parse(dumped)
        value.is_a?(String) ? value : nil
      rescue JSON::ParserError
        nil
      end

      def encrypt_cookie(name, hash, expires_at)
        @encrypted_cookies.encrypt(JSON.generate(hash), purpose: "cookie.#{name}", expires_at: expires_at)
      end

      def decrypt_cookie(name, raw)
        dumped = @encrypted_cookies.decrypt(raw, purpose: "cookie.#{name}")
        dumped && JSON.parse(dumped)
      rescue JSON::ParserError
        nil
      end

      # ActiveRecord::SignedId: purpose "user/avatar" and the like.
      def signed_id(id, purpose, expires_at: nil)
        @signed_ids.generate(id, purpose: purpose, expires_at: expires_at)
      end

      def find_signed_id(token, purpose)
        value = @signed_ids.verify(token, purpose: purpose)
        Integer(value) rescue nil
      end

      # User#attachable_sgid: to_sgid(expires_in: nil, for: "attachable")
      def attachable_sgid(model_name, id)
        @global_ids.generate("gid://campfire/#{model_name}/#{id}?expires_in", purpose: "attachable")
      end

      def signed_stream_name(name)
        return @turbo_streams.generate(name).freeze if Campfire.rust_caching_only?
        @stream_names[name] ||= @turbo_streams.generate(name).freeze
      end

      def verified_stream_name(signed)
        value = @turbo_streams.verify(signed)
        value.is_a?(String) ? value : value&.to_s
      end
    end

    # GlobalID#to_param: URL-safe Base64 of the GID URI, without padding.
    def self.gid_param(model_name, id)
      Base64.urlsafe_encode64("gid://campfire/#{model_name}/#{id}", padding: false)
    end
  end
end
