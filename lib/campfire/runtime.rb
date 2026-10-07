require "securerandom"

module Campfire
  ROOT = File.expand_path("../..", __dir__)

  # Process-wide state shared by requests: the database, secrets and caches.
  class Runtime
    attr_reader :db, :repo, :secrets, :fragment_cache, :vapid_public_key, :app_version, :git_revision

    def initialize
      @db = DB.new
      @repo = Repo.new(@db)
      @secrets = RailsCompat::Secrets.new(ENV.fetch("SECRET_KEY_BASE"))
      @fragment_cache = FragmentCache.new(ENV.fetch("FRAGMENT_CACHE_SIZE", 5_000).to_i)
      @vapid_public_key = ENV["VAPID_PUBLIC_KEY"]
      @app_version = ENV["APP_VERSION"].to_s.empty? ? (ENV["GIT_REVISION"].to_s.empty? ? "0" : ENV["GIT_REVISION"]) : ENV["APP_VERSION"]
      @git_revision = ENV["GIT_REVISION"]
      @avatar_tokens = {}
    end

    def account
      @repo.account
    end

    # Current.account&.logo&.attached?: there's no account before first run.
    def account_logo_attached?
      (account = self.account) && !@repo.attachment_blob("Account", account.id, "logo").nil?
    end

    def avatar_token(user_id)
      return @secrets.signed_id(user_id, "user/avatar").freeze if Campfire.rust_caching_only?
      @avatar_tokens[user_id] ||= @secrets.signed_id(user_id, "user/avatar").freeze
    end

    def all_emoji?(text)
      text.match?(/\A(\p{Emoji_Presentation}|\p{Extended_Pictographic}|️)+\z/u)
    end

    def blob_path(blob, disposition: nil)
      Storage.blob_path(self, blob, disposition: disposition)
    end
  end

  module Tokens
    BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".chars.freeze

    BASE36 = [ *"0".."9", *"a".."z" ].freeze

    # ActiveSupport's SecureRandom.base58, as has_secure_token uses it.
    def self.base58(length)
      Array.new(length) { BASE58[SecureRandom.random_number(58)] }.join
    end

    # SecureRandom.base36, as Active Storage generates blob keys.
    def self.base36(length)
      Array.new(length) { BASE36[SecureRandom.random_number(36)] }.join
    end
  end

  # A bounded per-process cache for rendered fragments, evicting the oldest entries first.
  class FragmentCache
    def initialize(limit)
      @limit = limit
      @entries = {}
    end

    def key?(key)
      @entries.key?(key)
    end

    def fetch(key)
      if (value = @entries.delete(key))
        @entries[key] = value
      else
        value = yield
        @entries[key] = value
        @entries.delete(@entries.first[0]) while @entries.size > @limit
        value
      end
    end
  end
end
