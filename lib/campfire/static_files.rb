require "zlib"
require "rack/mime"
require "time"

module Campfire
  # public/ served from memory: each file read and gzipped once per process, with Propshaft's
  # long-lived cache headers. Digested assets never change, so nothing needs invalidating.
  class StaticFiles
    Entry = Data.define(:body, :gzip, :type, :last_modified)

    def initialize(root, cache_control: "public, max-age=2592000")
      @root, @cache_control = File.expand_path(root), cache_control
      @entries = {}
    end

    def call(env)
      path = Rack::Utils.unescape_path(env["PATH_INFO"])
      entry = @entries[path] ||= Campfire.file_io { load(path) }
      return [ 404, { "content-type" => "text/plain" }, [ "Not found" ] ] unless entry

      headers = { "cache-control" => @cache_control, "content-type" => entry.type, "last-modified" => entry.last_modified }
      return partial(env, headers, entry.body) if env["HTTP_RANGE"]

      if entry.gzip && env["HTTP_ACCEPT_ENCODING"].to_s.include?("gzip")
        headers["content-encoding"] = "gzip"
        body = entry.gzip
      else
        body = entry.body
      end
      headers["content-length"] = body.bytesize.to_s
      [ 200, headers, env["REQUEST_METHOD"] == "HEAD" ? [] : [ body ] ]
    end

    private
      # Rack::Files' single byte ranges: 206 with the slice, uncompressed, and the Vary that Thruster
      # then adds a second Accept-Encoding to; 416 when nothing of the range is in the file.
      def partial(env, headers, body)
        ranges = Rack::Utils.get_byte_ranges(env["HTTP_RANGE"], body.bytesize)
        return [ 200, headers.merge("content-length" => body.bytesize.to_s), env["REQUEST_METHOD"] == "HEAD" ? [] : [ body ] ] if ranges.nil? || ranges.size > 1
        if ranges.empty?
          return [ 416, headers.merge("content-range" => "bytes */#{body.bytesize}", "content-length" => "0"), [] ]
        end

        range = ranges.first
        slice = body.byteslice(range)
        headers.merge!("content-range" => "bytes #{range.begin}-#{range.end}/#{body.bytesize}", "content-length" => slice.bytesize.to_s, "vary" => "Accept-Encoding")
        [ 206, headers, env["REQUEST_METHOD"] == "HEAD" ? [] : [ slice ] ]
      end

      def load(path)
        file = File.expand_path(File.join(@root, path))
        return nil unless file.start_with?("#{@root}/") && File.file?(file)
        body = File.binread(file).freeze
        type = Rack::Mime.mime_type(File.extname(file), "application/octet-stream")
        # Thruster compresses everything, so every file gets a gzip copy (made once).
        gzip = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, Zlib::MAX_WBITS + 16).deflate(body, Zlib::FINISH).freeze
        Entry.new(body, gzip, type, File.mtime(file).httpdate)
      end
  end

  # /assets/* from memory, ahead of the router, as Sinatra's config.ru mapped it.
  class AssetFiles
    def initialize(app)
      @app = app
      @files = StaticFiles.new(File.join(ROOT, "public"))
    end

    def call(env)
      env["PATH_INFO"].start_with?("/assets/") ? @files.call(env) : @app.call(env)
    end
  end
end
