module Campfire
  # What Rack::MethodOverride and Rails' HEAD handling do ahead of the router: a form's `_method`
  # turns a POST into PATCH, PUT or DELETE, and a HEAD request runs its GET route with the body
  # dropped. Rage routes on REQUEST_METHOD before it parses the body, so the override reads the
  # form itself; the body is only parsed when it mentions `_method`.
  class RequestMethod
    OVERRIDABLE = %w[ GET HEAD PUT POST DELETE OPTIONS PATCH LINK UNLINK ].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      case env["REQUEST_METHOD"]
      when "POST" then override(env)
      when "HEAD"
        env["REQUEST_METHOD"] = "GET"
        status, headers, body = @app.call(env)
        body.close if body.respond_to?(:close)
        return [ status, headers, [] ]
      end
      @app.call(env)
    end

    private
      def override(env)
        method = env["HTTP_X_HTTP_METHOD_OVERRIDE"] || form_method(env)
        method = method.to_s.upcase
        if OVERRIDABLE.include?(method)
          env["rack.methodoverride.original_method"] = "POST"
          env["REQUEST_METHOD"] = method
        end
      end

      def form_method(env)
        type = env["CONTENT_TYPE"].to_s
        return unless type.start_with?("application/x-www-form-urlencoded", "multipart/form-data")
        input = env["rack.input"] or return
        raw = input.read.to_s
        input.rewind
        return unless raw.include?("_method")
        Rack::Request.new(env).POST["_method"].tap { input.rewind }
      rescue EOFError, Rack::Multipart::Error
        nil
      end
  end
end
