require "securerandom"

module Campfire
  # ActionDispatch::RequestId: X-Request-Id on every response the app answers, the client's own
  # (letters, digits, _, - and @, at most 255) or a new UUID. Files from public/ are served above it
  # in Rails' stack (ActionDispatch::Static), so they get none, as in the Rust port.
  class RequestId
    STATIC = "campfire.static_file".freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      id = env["HTTP_X_REQUEST_ID"].to_s.gsub(/[^\w\-@]/, "")[0, 255]
      id = SecureRandom.uuid if id.empty?
      env["action_dispatch.request_id"] = id
      status, headers, body = @app.call(env)
      headers["x-request-id"] = id unless env[STATIC]
      [ status, headers, body ]
    end
  end
end
