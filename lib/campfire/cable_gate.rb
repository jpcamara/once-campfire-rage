require "rack/request"

module Campfire
  # ActionCable::Server::Base#call's checks before a connection is opened (as the Rust port's
  # cable/src/server.rs does): only a GET WebSocket upgrade whose Origin is this app's own
  # (allow_same_origin_as_host, the reference's only allowed origin) reaches the cable server.
  # Anything else gets Action Cable's 404 "Page not found".
  class CableGate
    PAGE_NOT_FOUND = [ 404, { "content-type" => "text/plain; charset=utf-8" }, [ "Page not found" ] ].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      return page_not_found unless websocket?(env) && allowed_origin?(env)
      @app.call(env)
    end

    private
      def websocket?(env)
        env["REQUEST_METHOD"] == "GET" &&
          env["HTTP_CONNECTION"].to_s.split(",").any? { it.strip.casecmp?("upgrade") } &&
          env["HTTP_UPGRADE"].to_s.casecmp?("websocket")
      end

      def allowed_origin?(env)
        proto = Rack::Request.new(env).ssl? ? "https" : "http"
        allowed = env["HTTP_ORIGIN"] == "#{proto}://#{env["HTTP_HOST"]}"
        warn "Request origin not allowed: #{env["HTTP_ORIGIN"]}" unless allowed
        allowed
      end

      def page_not_found
        status, headers, body = PAGE_NOT_FOUND
        [ status, headers.dup, body ]
      end
  end
end
