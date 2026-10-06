module Campfire
  # Thruster's response cache (as the Rust port reproduces it, crates/kit/src/front/cache.rs): GET
  # and HEAD responses that say `public` with a positive `s-max-age` or `max-age`, and no
  # `no-cache` or `Vary: *`, are kept in memory until they expire and served again with
  # `X-Cache: hit` to any request with the same method, host, path, query and values of the headers
  # the response varies on. A cacheable response loses its Set-Cookie. Per process, bounded in bytes
  # like Thruster's 64 MB cache with 1 MB items.
  class ResponseCache
    CAPACITY = 64 * 1024 * 1024
    MAX_ITEM = 1024 * 1024
    MAX_URI = 2048
    BODILESS_HEADERS = %w[ content-type content-length ].freeze

    Entry = Data.define(:status, :headers, :body, :expires_at, :size)

    def initialize(app)
      @app = app
      @vary = {}    # key without variant => the response's Vary names
      @entries = {} # full key => Entry, least recently used first
      @size = 0
    end

    def call(env)
      return @app.call(env) unless cacheable_request?(env)

      base = "#{env["REQUEST_METHOD"]} #{env["HTTP_HOST"]} #{env["PATH_INFO"]}?#{env["QUERY_STRING"]}"
      if (names = @vary[base]) && (entry = lookup(key(base, names, env)))
        return hit(entry, env)
      end

      status, headers, body = @app.call(env)
      if (lifetime = lifetime(status, headers))
        headers.delete("set-cookie")
        content = +""
        body.each { content << it }
        body.close if body.respond_to?(:close)
        body = [ content ]
        store(base, env, status, headers, content.freeze, lifetime)
      end
      [ status, headers, body ]
    end

    private
      def cacheable_request?(env)
        %w[ GET HEAD ].include?(env["REQUEST_METHOD"]) && env["HTTP_CONNECTION"] != "Upgrade" &&
          env["HTTP_UPGRADE"] != "websocket" && env["HTTP_RANGE"].to_s.empty? &&
          env["PATH_INFO"].to_s.bytesize + env["QUERY_STRING"].to_s.bytesize < MAX_URI
      end

      def lifetime(status, headers)
        return if status < 200 || status > 399 || status == 304
        return if headers["vary"].to_s.include?("*")
        cache_control = headers["cache-control"].to_s
        return unless cache_control.match?(/\bpublic\b/) && !cache_control.match?(/\bno-cache\b/)
        seconds = cache_control[/\bs-max-age=(\d+)\b/, 1] || cache_control[/\bmax-age=(\d+)\b/, 1]
        seconds.to_i if seconds && seconds.to_i > 0
      end

      def key(base, names, env)
        names.reduce(base) { |key, name| "#{key}\n#{name}=#{env["HTTP_#{name.upcase.tr("-", "_")}"]}" }
      end

      def lookup(key)
        entry = @entries.delete(key) or return
        if entry.expires_at < now
          @size -= entry.size
          return
        end
        @entries[key] = entry
      end

      def store(base, env, status, headers, content, lifetime)
        names = headers["vary"].to_s.split(",").map { it.strip.downcase }.reject(&:empty?).sort
        kept = headers.to_h.except("x-cache").freeze
        key = key(base, names, env)
        size = content.bytesize + key.bytesize + kept.sum { |name, value| name.bytesize + value.to_s.bytesize }
        return if size > MAX_ITEM

        @vary[base] = names
        if (previous = @entries.delete(key))
          @size -= previous.size
        end
        @entries[key] = Entry.new(status, kept, content, now + lifetime, size)
        @size += size
        while @size > CAPACITY
          _, evicted = @entries.shift
          @size -= evicted.size
        end
      end

      def hit(entry, env)
        headers = entry.headers.merge("x-cache" => "hit")
        if (etag = entry.headers["etag"]) && env["HTTP_IF_NONE_MATCH"].to_s.split(",").any? { it.strip == etag }
          [ 304, headers.except(*BODILESS_HEADERS), [] ]
        else
          [ entry.status, headers, [ entry.body ] ]
        end
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
