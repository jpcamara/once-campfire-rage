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

    # Prepared statements by shard, type and SQL, named in the order they're first used.
    class Statements
      def initialize(sequel)
        @sequel = sequel
        @statements = {}
      end

      def fetch(server, type, sql, arity)
        @statements[[ server, type, sql, arity ]] ||= begin
          binds = Array.new(arity) { :"$a#{it}" }
          @sequel.dataset.with_sql(sql, *binds).server(server).prepare(type, :"q#{@statements.size}")
        end
      end
    end

    # Queries on one shard. Rows come back as arrays, in the order of the SELECT's columns.
    class Connection
      ARGUMENT_NAMES = Array.new(64) { :"a#{it}" }.freeze

      def initialize(sequel, statements, server)
        @sequel, @statements, @server = sequel, statements, server
      end

      def rows(sql, *binds)
        call(:select, sql, binds).map!(&:values)
      end

      def row(sql, *binds)
        call(:select, sql, binds).first&.values
      end

      def value(sql, *binds)
        call(:select, sql, binds).first&.first&.last
      end

      # The number of rows changed.
      def run(sql, *binds)
        call(:update, sql, binds)
      end

      def last_insert_row_id
        @sequel.synchronize(@server) { it.last_insert_row_id }
      end

      private
        # Strings from Iodine (headers, the client's address) arrive binary-encoded, and SQLite binds
        # those as blobs, which never equal text. Everything the app binds is text.
        def call(type, sql, binds)
          arguments = {}
          binds.each_with_index do |value, i|
            value = value.dup.force_encoding(Encoding::UTF_8) if value.is_a?(String) && value.encoding == Encoding::BINARY
            arguments[ARGUMENT_NAMES[i]] = value
          end
          @statements.fetch(@server, type, sql, binds.size).call(arguments)
        end
    end

    def initialize
      @sequel = self.class.sequel
      statements = Statements.new(@sequel)
      @reader = Connection.new(@sequel, statements, :read_only)
      @writer = Connection.new(@sequel, statements, :default)
      @write_lock = Mutex.new
    end

    def rows(...) = @reader.rows(...)
    def row(...) = @reader.row(...)
    def value(...) = @reader.value(...)

    def transaction
      @write_lock.synchronize do
        @sequel.transaction(server: :default, mode: :immediate) { yield @writer }
      end
    end
  end
end
