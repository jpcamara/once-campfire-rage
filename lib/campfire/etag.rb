require "digest"

module Campfire
  # Rack::ETag as Rails runs it: a weak ETag on 200 responses that don't set one (whatever the
  # method), from the body's MD5, and a 304 when a GET's client already has it. Pages with large bodies set their own ETag
  # from what they're rendered from instead (as the Rust port does), which saves hashing the body.
  class ETag
    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      return [ status, headers, body ] unless status == 200

      unless headers["etag"] || headers["last-modified"] || headers["cache-control"].to_s.include?("no-cache")
        content = +""
        body.each { content << it }
        body.close if body.respond_to?(:close)
        body = [ content ]
        headers["etag"] = %(W/"#{Digest::MD5.hexdigest(content)}") unless content.empty?
      end

      if headers["etag"] && env["REQUEST_METHOD"] == "GET" && env["HTTP_IF_NONE_MATCH"] == headers["etag"]
        body.close if body.respond_to?(:close)
        headers.delete("content-length")
        return [ 304, headers, [] ]
      end
      [ status, headers, body ]
    end
  end
end
