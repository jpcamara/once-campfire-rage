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
      entry = @entries[path] ||= load(path)
      return [ 404, { "content-type" => "text/plain" }, [ "Not found" ] ] unless entry

      headers = { "cache-control" => @cache_control, "content-type" => entry.type, "last-modified" => entry.last_modified }
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
