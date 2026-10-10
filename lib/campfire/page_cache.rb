module Campfire
  # Finished private pages: the room, messages, sidebar and search responses of a signed-in user,
  # kept whole (body and its gzip) until the database changes. This follows upstream Rails'
  # completed-response cache (basecamp/once-campfire ac73267, 0f5d0b2 and 8d02540:
  # app/models/response_cache.rb, app/controllers/concerns/cached_responses.rb), which carries over
  # the C port's versioned response cache; the Rust port has one too (once-campfire-rust d09811c,
  # crates/campfire/src/response_cache.rs).
  #
  # - The database version is captured before authentication and checked again at lookup and at
  #   admission, so a commit during authentication or rendering can't put a page made from an older
  #   snapshot under the new version. Any commit, from this process or another writer, drops
  #   every entry (PRAGMA data_version, observed by DB::ReadCache).
  # - Authentication, room access and cookies run on every request; only the render is skipped.
  # - Entries also expire after TTL seconds, as the Rust port's do, for output that depends on the
  #   clock rather than the database.
  # - Bounded by bytes: CAMPFIRE_RESPONSE_CACHE_MB per process (default 64, 0 disables), 1 MB per
  #   entry, 2 KB per key; the oldest entries go first.
  # - Concurrent renders of the same page collapse into one, on 16 striped locks (8d02540).
  class PageCache
    MAX_ENTRY_BYTES = 1024 * 1024
    MAX_KEY_BYTES = 2048
    TTL = 15
    KEPT_HEADERS = %w[ content-type cache-control etag last-modified vary link ].freeze

    Entry = Data.define(:body, :headers, :expires_at)

    def self.instance = (@instance ||= new)

    def initialize(megabytes = ENV.fetch("CAMPFIRE_RESPONSE_CACHE_MB", "64").to_i)
      @budget = [ megabytes, 0 ].max * 1024 * 1024
      @mutex = Mutex.new
      @entries = {}
      @bytes = 0
      @version = nil
      @render_locks = Array.new(16) { Mutex.new }
    end

    def enabled? = @budget.positive?

    # The entry for `key`, if it was made at `version` and that's still `current`.
    def read(key, version, current)
      return unless version == current
      @mutex.synchronize do
        observe(current)
        entry = @entries[key]&.first
        if entry && entry.expires_at < now
          _, size = @entries.delete(key)
          @bytes -= size
          entry = nil
        end
        entry
      end
    end

    def write(key, version, current, body, headers)
      size = key.bytesize + body.bytesize + headers.sum { |name, value| name.bytesize + value.to_s.bytesize } + 256
      return if version != current || key.bytesize > MAX_KEY_BYTES || size > [ @budget, MAX_ENTRY_BYTES ].min

      @mutex.synchronize do
        observe(current)
        return if @entries.key?(key)
        while @entries.any? && @bytes + size > @budget
          _, (_, removed) = @entries.shift
          @bytes -= removed
        end
        entry = Entry.new(body.freeze, headers.freeze, now + TTL)
        @entries[key] = [ entry, size ]
        @bytes += size
        entry
      end
    end

    # Renders of one page by concurrent requests wait for the first, without a lock per page.
    def synchronize_render(key, version, &)
      @render_locks[[ key, version ].hash % @render_locks.length].synchronize(&)
    end

    private
      def observe(current)
        return if @version == current
        @entries.clear
        @bytes = 0
        @version = current
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
