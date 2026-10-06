require "zlib"

module Campfire
  # What Thruster does in front of the Rails app: gzip every response that has a body (any status,
  # type or size) for clients that accept it, add Vary: Accept-Encoding, and an X-Cache header
  # (bypass for writes; this app keeps no shared response cache, so reads are always a miss).
  class Compression
    NO_BODY = [ 101, 204, 304 ].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      return [ status, headers, body ] if status == 101 || status == 0 # 0: Iodine's WebSocket upgrade

      headers["x-cache"] = %w[ GET HEAD ].include?(env["REQUEST_METHOD"]) ? "miss" : "bypass"
      # Writes pass through both the Rails app's Rack::Deflater and Thruster's gzip handler, which each
      # add Accept-Encoding; reads are answered past Rack::Deflater's addition, so get one.
      encodings = %w[ GET HEAD ].include?(env["REQUEST_METHOD"]) ? [ "Accept-Encoding" ] : [ "Accept-Encoding", "Accept-Encoding" ]
      headers["vary"] = [ headers["vary"], *encodings ].compact.join(",")
      return [ status, headers, body ] if NO_BODY.include?(status) || env["REQUEST_METHOD"] == "HEAD" || headers.key?("content-range")
      return [ status, headers, body ] if headers["content-encoding"] || !env["HTTP_ACCEPT_ENCODING"].to_s.include?("gzip")

      if body.is_a?(FragmentBody)
        compressed = body.gzip
      else
        content = +""
        body.each { content << it }
        body.close if body.respond_to?(:close)
        compressed = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, Zlib::MAX_WBITS + 16).deflate(content, Zlib::FINISH)
      end
      headers["content-encoding"] = "gzip"
      headers["content-length"] = compressed.bytesize.to_s
      [ status, headers, [ compressed ] ]
    end
  end
end
