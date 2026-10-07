require "rack/request"

module Campfire
  # The reference's production.rb: config.assume_ssl and config.force_ssl, both on unless DISABLE_SSL
  # is set (as the Rust port's kit/src/app.rs and adapter.rs do).
  module SSL
    def self.enabled? = ENV["DISABLE_SSL"].to_s.strip.empty?

    # ActionDispatch::AssumeSSL: a TLS-terminating proxy is in front, so every request is HTTPS.
    class Assume
      def initialize(app)
        @app = app
      end

      def call(env)
        env["HTTPS"] = "on"
        env["HTTP_X_FORWARDED_PORT"] = "443"
        env["HTTP_X_FORWARDED_PROTO"] = "https"
        env["rack.url_scheme"] = "https"
        @app.call(env)
      end
    end

    # ActionDispatch::SSL: plain HTTP is redirected to HTTPS (301 for GET and HEAD, 308 otherwise);
    # HTTPS responses get HSTS and only secure cookies.
    class Force
      HSTS = "max-age=63072000; includeSubDomains".freeze

      def initialize(app)
        @app = app
      end

      def call(env)
        request = Rack::Request.new(env)
        return redirect_to_https(request) unless request.ssl?

        status, headers, body = @app.call(env)
        headers["strict-transport-security"] = HSTS
        flag_cookies_as_secure(headers)
        [ status, headers, body ]
      end

      private
        def redirect_to_https(request)
          status = request.get? || request.head? ? 301 : 308
          [ status, { "content-type" => "text/html", "location" => "https://#{request.host}#{request.fullpath}" }, [] ]
        end

        def flag_cookies_as_secure(headers)
          return unless (cookies = headers["set-cookie"])
          cookies = cookies.is_a?(Array) ? cookies : cookies.split("\n")
          headers["set-cookie"] = cookies.map do |cookie|
            cookie.split(";").drop(1).any? { it.strip.casecmp?("secure") } ? cookie : "#{cookie}; secure"
          end
        end
    end
  end
end
