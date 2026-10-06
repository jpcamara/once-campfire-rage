module Campfire
  # What Rack::MethodOverride and Rails' HEAD handling do ahead of the router: a form's `_method`
  # turns a POST into PATCH, PUT or DELETE, and a HEAD request runs its GET route with the body
  # dropped. Rage routes on REQUEST_METHOD before it parses the body, so the override reads the
  # form itself; the body is only parsed when it mentions `_method`.
  #
  # It also routes the one format-suffixed path the app's own forms post to: `form_with model:
  # Current.account` gives `/account.<id>` (a singular resource's path helper puts the record in the
  # format slot), which Rails routes to accounts#update. Rage's router has no `(.:format)`.
  class RequestMethod
    OVERRIDABLE = %w[ GET HEAD PUT POST DELETE OPTIONS PATCH LINK UNLINK ].freeze
    ACCOUNT_WITH_FORMAT = %r{\A/account\.[^/]+\z}
    TRACE = ENV["CAMPFIRE_TRACE"] # debugging: each request's start and end on stdout

    def initialize(app)
      @app = app
    end

    def call(env)
      TRACE ? traced(env) : dispatch(env)
    end

    private
      def traced(env)
        id = "#{Process.pid}-#{env.object_id}"
        $stdout.puts("> #{id} #{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}")
        $stdout.flush
        dispatch(env).tap { $stdout.puts("< #{id} #{it[0]}"); $stdout.flush }
      end

      def dispatch(env)
        env["PATH_INFO"] = "/account" if ACCOUNT_WITH_FORMAT.match?(env["PATH_INFO"])
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
        # Parse the bytes already read, not rack.input: Iodine's #read(length, buffer) copies into the
        # buffer without clearing Ruby's cached coderange, so Rack's multipart parser takes a binary
        # part (an avatar or logo upload) for ASCII and raises "invalid byte sequence in UTF-8".
        Rack::Request.new(env.merge("rack.input" => StringIO.new(raw))).POST["_method"]
      rescue EOFError, Rack::Multipart::Error
        nil
      end
  end
end
