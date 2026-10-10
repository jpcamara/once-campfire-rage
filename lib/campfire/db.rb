require "sequel"

module Campfire
  # Sequel over SQLite. Each process opens one Sequel database with two shards: :read_only, where
  # reads go, and :default, where transactions run. Sequel's pool gives each thread one connection
  # per shard, and Rage serves every request on one thread, so a process holds one reader and one
  # writer connection. A read runs to completion without yielding to the fiber scheduler, so fibers
  # never see each other's half-finished statements.
  #
  # Every query is a Sequel prepared statement, prepared once per connection and cached by its SQL.
  # Sequel's type conversion is off: values come back as SQLite stores them (Rails' text timestamps
  # among them), and the app parses them where it needs to.
  #
  # Writes take a fiber-aware lock, then BEGIN IMMEDIATE. Sequel tracks transactions per thread, so
  # without the lock a second fiber would join the first one's open transaction. The writer waits
  # for other processes with a busy handler that sleeps, so other fibers run meanwhile.
  class DB
    BUSY_TIMEOUT_MS = 5_000

    class << self
      def path
        ENV.fetch("DATABASE_PATH") { File.join(ENV.fetch("STORAGE_PATH", "storage"), "db", "production.sqlite3") }
      end

      # One Sequel database per process: connections don't survive Iodine's fork.
      def sequel
        return @sequel if @sequel_pid == Process.pid
        @sequel_pid = Process.pid
        # SQLite's own LIKE (case-insensitive for ASCII), as Rails leaves it; Sequel turns it case-sensitive.
        @sequel = Sequel.sqlite(path, servers: { read_only: {} }, max_connections: 8, timeout: BUSY_TIMEOUT_MS,
          case_sensitive_like: false, after_connect: ->(connection, server) { configure(connection, server) })
        @sequel.conversion_procs.clear
        @sequel
      end

      # `IN (?, ?, ...)` for a list of ids; each list length is its own prepared statement.
      def in_list(count)
        Array.new(count, "?").join(", ")
      end

      private
        def configure(connection, server)
          connection.busy_handler_timeout = BUSY_TIMEOUT_MS if server == :default
          connection.execute("PRAGMA journal_mode = WAL")
          connection.execute("PRAGMA synchronous = NORMAL")
          connection.execute("PRAGMA foreign_keys = ON")
          connection.execute("PRAGMA mmap_size = 0")
        end
    end

    # Prepared statements by shard and SQL, registered with Sequel once and named in the order they're
    # first used.
    class Statements
      def initialize(sequel)
        @sequel = sequel
        @names = {}
      end

      def fetch(server, sql, arity)
        @names[[ server, sql, arity ]] ||= :"q#{@names.size}".tap do |name|
          binds = Array.new(arity) { :"$a#{it}" }
          @sequel.dataset.with_sql(sql, *binds).server(server).prepare(:select, name)
        end
      end
    end

    # Queries on one shard. Rows come back as arrays, in the order of the SELECT's columns.
    #
    # A statement runs through Sequel::Database#execute by its prepared statement's name: Sequel's
    # pool, cached SQLite statement and error handling, without binding through a cloned dataset or
    # building a hash per row (which was a fifth of a post's time).
    class Connection
      ARGUMENT_KEYS = Array.new(256) { "a#{it}".freeze }.freeze # more for longer IN lists, made as needed

      def initialize(sequel, statements, server)
        @sequel, @statements, @server = sequel, statements, server
      end

      def rows(sql, *binds)
        rows = nil
        @sequel.execute(@statements.fetch(@server, sql, binds.size), server: @server, arguments: arguments(binds)) { rows = it.to_a }
        rows
      end

      def row(sql, *binds) = rows(sql, *binds).first
      def value(sql, *binds) = rows(sql, *binds).first&.first

      # The number of rows changed.
      def run(sql, *binds)
        @sequel.execute_dui(@statements.fetch(@server, sql, binds.size), server: @server, arguments: arguments(binds))
      end

      def last_insert_row_id
        @sequel.synchronize(@server) { it.last_insert_row_id }
      end

      private
        # Strings from Iodine (headers, the client's address) arrive binary-encoded, and SQLite binds
        # those as blobs, which never equal text. Everything the app binds is text.
        def arguments(binds)
          arguments = {}
          binds.each_with_index do |value, i|
            value = value.dup.force_encoding(Encoding::UTF_8) if value.is_a?(String) && value.encoding == Encoding::BINARY
            arguments[ARGUMENT_KEYS[i] || "a#{i}"] = value
          end
          arguments
        end
    end

    # Read results, kept until the database changes. PRAGMA data_version on the reader connection
    # changes whenever any other connection commits: this process's writer, or another worker's. It's
    # checked once per fiber (each request, job and cable message runs in its own), and the cache is
    # also cleared after this process's own commits. Rows are frozen, as they're shared.
    class ReadCache
      LIMIT = 8192

      def initialize(sequel)
        @sequel = sequel
        @entries = {}
        @version = nil
        @checked = nil
        @generation = 0
      end

      # Bumped whenever the cache is cleared: anything derived from reads can be kept under it.
      def generation
        refresh unless @checked.equal?(Fiber.current)
        @generation
      end

      # The generation as of now: data_version read again, even if this fiber already checked it.
      def current_generation
        refresh
        @generation
      end

      def fetch(sql, binds)
        return yield.each(&:freeze).freeze if Campfire.rust_caching_only?
        refresh unless @checked.equal?(Fiber.current)
        key = [ sql, *binds ]
        if (rows = @entries.delete(key))
          @entries[key] = rows
        else
          rows = @entries[key] = yield.each(&:freeze).freeze
          @entries.delete(@entries.first[0]) while @entries.size > LIMIT
          rows
        end
      end

      def clear
        @entries.clear
        @generation += 1
        @checked = nil
      end

      private
        def refresh
          @checked = Fiber.current
          version = @sequel.synchronize(:read_only) { it.get_first_value("PRAGMA data_version") }
          unless version == @version
            @entries.clear
            @generation += 1
          end
          @version = version
        end
    end

    def initialize
      @sequel = self.class.sequel
      statements = Statements.new(@sequel)
      @reader = Connection.new(@sequel, statements, :read_only)
      @writer = Connection.new(@sequel, statements, :default)
      @write_lock = Mutex.new
      @cache = ReadCache.new(@sequel)
    end

    def rows(sql, *binds) = @cache.fetch(sql, binds) { @reader.rows(sql, *binds) }
    def generation = @cache.generation
    def current_generation = @cache.current_generation
    def row(sql, *binds) = rows(sql, *binds).first
    def value(sql, *binds) = rows(sql, *binds).first&.first

    def transaction
      @write_lock.synchronize do
        @sequel.transaction(server: :default, mode: :immediate) { yield @writer }
      ensure
        @cache.clear
      end
    end
  end
end
