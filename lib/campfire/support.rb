require "rqrcode"

module Campfire
  # Users::AvatarsController and Accounts::LogosController
  module Avatars
    SVG = <<~SVG.freeze
      <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
        viewBox="0 0 512 512" class="avatar" aria-hidden="true">
        <defs>
          <clipPath id="porthole">
            <circle cx="50%%" cy="50%%" r="50%%" />
          </clipPath>
        </defs>

        <g>
          <rect width="100%%" height="100%%" rx="50" fill="%s" />

          <text x="50%%" y="50%%" fill="#FFFFFF"
            text-anchor="middle" dy="0.35em"
            %s
            font-family="-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif"
            font-size="230"
            font-weight="800"
            letter-spacing="-5">
            %s
          </text>
        </g>
      </svg>
    SVG

    module_function

    def show(app, token)
      runtime = app.runtime
      user_id = runtime.secrets.find_signed_id(token, "user/avatar")
      user = user_id && runtime.repo.user(user_id)
      app.head_response(404, in_action: true) unless user

      app.etag Digest::MD5.hexdigest("users/#{user.id}-#{user.updated_at}"), kind: :weak
      app.headers "Cache-Control" => "max-age=1800, public, stale-while-revalidate=604800"
      app.headers "Vary" => "Accept" if app.vary_by_accept?

      if (variant = avatar_variant(runtime, user))
        app.send_inline_file Storage.path_for(variant.key), "image/webp"
      elsif user.bot?
        app.send_inline_file File.join(ROOT, "public/default-bot-avatar.svg"), "image/svg+xml"
      else
        app.without_security_headers
        app.headers "Content-Type" => "image/svg+xml; charset=utf-8"
        initials_svg(user)
      end
    end

    # Users::AvatarsController#render_initials, kept per user version.
    def initials_svg(user)
      (@initials ||= {})[[ user.id, user.name ]] ||= begin
        initials = user.initials
        length = initials.size >= 3 ? 'textLength="85%" lengthAdjust="spacingAndGlyphs"' : ""
        format(SVG, View::AVATAR_COLORS[Zlib.crc32(user.to_param) % View::AVATAR_COLORS.size], length, HTML.h(initials)).freeze
      end
    end

    # User::Avatar#avatar_variant: the 512px webp square, built on first request.
    def avatar_variant(runtime, user)
      blob = runtime.repo.attachment_blob("User", user.id, "avatar") or return nil
      return nil unless Attachments.variable?(blob)
      # The :square named variant: Rails digests its format as a Symbol, so this finds existing variants.
      Uploads.variant_blob(Context.new(runtime), blob, { "format" => :webp, "resize_to_limit" => [ 512, 512 ] })
    end

    def account_logo(app)
      runtime = app.runtime
      account = runtime.account
      app.etag Digest::MD5.hexdigest("accounts/#{account.id}-#{account.updated_at}"), kind: :weak
      app.headers "Cache-Control" => "max-age=300, public, stale-while-revalidate=604800"
      app.headers "Vary" => "Accept" if app.vary_by_accept?
      small = app.params["size"] == "small"
      blob = runtime.repo.attachment_blob("Account", account.id, "logo")
      if blob && Attachments.variable?(blob)
        size = small ? 192 : 512
        variant = Uploads.variant_blob(Context.new(runtime), blob, { "format" => :png, "resize_to_limit" => [ size, size ] })
        app.send_inline_file Storage.path_for(variant.key), "image/png"
      else
        app.send_inline_file File.join(ROOT, "public/logos", small ? "app-icon-192.png" : "app-icon.png"), "image/png"
      end
    end
  end

  # The bits of a request context the data helpers need, for work outside a request.
  Context = Data.define(:runtime) do
    def db = runtime.db
    def repo = runtime.repo
  end

  module Searches
    module_function

    # Search.record: find_or_create_by(query:).touch, then keep the ten most recent.
    def record(ctx, user, query)
      return if query.to_s.empty?
      now = TimeFormat.now_text
      ctx.db.transaction do |w|
        if (id = w.value("SELECT id FROM searches WHERE user_id = ? AND query = ? LIMIT 1", user.id, query))
          w.run("UPDATE searches SET updated_at = ? WHERE id = ?", now, id)
        else
          w.run("INSERT INTO searches (created_at, query, updated_at, user_id) VALUES (?, ?, ?, ?)", now, query, now, user.id)
          w.run(<<~SQL, user.id, user.id)
            DELETE FROM searches WHERE user_id = ? AND id NOT IN (SELECT id FROM searches WHERE user_id = ? ORDER BY updated_at DESC LIMIT 10)
          SQL
        end
      end
    end
  end

  module QrCodes
    module_function

    def show(app, id)
      url = Base64.urlsafe_decode64(id)
      app.headers "Cache-Control" => "max-age=31556952, public" # 1.year
      app.headers "Content-Type" => "image/svg+xml; charset=utf-8"
      RQRCode::QRCode.new(url).as_svg(viewbox: true, fill: :white, color: :black)
    end
  end

  # Background work in Rage::Deferred, like the Rust port's in-process queues: tasks run in fibers
  # in the worker that queued them, held in memory only. A failed job is logged and dropped.
  module Jobs
    class Task
      include Rage::Deferred::Task
      max_retries 0

      def perform(target, method, *args)
        Campfire.const_get(target).public_send(method, *args)
      end
    end

    def self.later(target, method, *args)
      Task.enqueue(target.name.delete_prefix("Campfire::"), method, *args)
    end

    def self.runtime = Campfire.runtime
  end

  # Room::MessagePusher over Push::Subscription: payloads go only to permitted push services.
  module Push
    PERMITTED_HOSTS = %w[ jmt17.google.com fcm.googleapis.com updates.push.services.mozilla.com web.push.apple.com notify.windows.com ].freeze

    module_function

    # A text message's body, plain text and creator come from the request that posted it; otherwise
    # they're loaded.
    def deliver_for_message(_runtime, room_id, message_id, body = nil, plain = nil, creator_id = nil)
      runtime = Jobs.runtime
      repo = runtime.repo
      room = repo.room(room_id) or return
      if creator_id
        creator = repo.user(creator_id)
      else
        row = runtime.db.row("SELECT #{Message.columns} FROM messages WHERE id = ?", message_id) or return
        message = Message.new(*row)
        creator = repo.user(message.creator_id)
        body = repo.bodies([ message.id ])[message.id]
        attachment = repo.message_attachments([ message.id ])[message.id]
        plain = Messages.plain_text_body(Context.new(runtime), body, attachment)
      end
      payload =
        if room.direct?
          { title: creator.name, body: plain, path: "/rooms/#{room.id}" }
        else
          { title: room.name, body: "#{creator.name}: #{plain}", path: "/rooms/#{room.id}" }
        end

      cutoff = (Time.now.utc - Memberships::CONNECTION_TTL).strftime("%Y-%m-%d %H:%M:%S.%6N")
      base = <<~SQL
        SELECT push_subscriptions.id, push_subscriptions.endpoint, push_subscriptions.p256dh_key, push_subscriptions.auth_key, push_subscriptions.user_id
        FROM push_subscriptions INNER JOIN users ON users.id = push_subscriptions.user_id INNER JOIN memberships ON memberships.user_id = users.id
        WHERE memberships.involvement != 'invisible' AND (memberships.connected_at IS NULL OR memberships.connected_at < ?)
        AND memberships.room_id = ? AND memberships.user_id != ?
      SQL
      everything = runtime.db.rows("#{base} AND memberships.involvement = 'everything'", cutoff, room.id, creator.id)
      mentionee_ids = Mentions.user_ids(body.to_s)
      mentions = mentionee_ids.empty? ? [] :
        runtime.db.rows("#{base} AND memberships.involvement = 'mentions' AND push_subscriptions.user_id IN (#{DB.in_list(mentionee_ids.size)})", cutoff, room.id, creator.id, *mentionee_ids)

      (everything + mentions).each do |id, endpoint, p256dh, auth, user_id|
        next unless permitted?(endpoint)
        badge = runtime.db.value("SELECT COUNT(*) FROM memberships WHERE user_id = ? AND unread_at IS NOT NULL", user_id)
        deliver(runtime, id, endpoint, p256dh, auth, payload, badge)
      end
    end

    def test_body
      "This is a test notification"
    end

    def permitted?(endpoint)
      uri = URI.parse(endpoint.to_s)
      host = uri.host.to_s.downcase
      uri.scheme == "https" && uri.port == 443 && PERMITTED_HOSTS.any? { host == it || host.end_with?(".#{it}") }
    rescue URI::InvalidURIError
      false
    end

    def deliver(runtime, id, endpoint, p256dh, auth, payload, badge)
      require "web-push"
      message = JSON.generate(title: payload[:title], options: { body: payload[:body], icon: "/account/logo", data: { path: payload[:path], badge: badge } })
      WebPush.payload_send(message: message, endpoint: endpoint, p256dh: p256dh, auth: auth, urgency: "high",
        vapid: { subject: "mailto:support@37signals.com", public_key: ENV["VAPID_PUBLIC_KEY"], private_key: ENV["VAPID_PRIVATE_KEY"] })
    rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription, OpenSSL::OpenSSLError
      # WebPush::Pool: expired subscriptions and ones whose keys don't work are removed.
      runtime.db.transaction { |w| w.run("DELETE FROM push_subscriptions WHERE id = ?", id) }
    rescue => error
      warn "push failed: #{error.class}: #{error.message}"
    end
  end

  # Message::Mentionee: the users a body mentions, from their attachment sgids.
  module Mentions
    module_function

    def user_ids(body)
      return [] unless body.include?("action-text-attachment")
      RichText.fragment(body).css(RichText::ATTACHMENT_TAG).filter_map { GlobalIds.user_id_from_sgid(it["sgid"]) }.uniq
    end
  end

  module GlobalIds
    module_function

    # lib/rails_ext/action_text_attachables.rb: mentions are located without checking the signature.
    def user_id_from_sgid(sgid)
      message = sgid.to_s.split("--").first or return nil
      decoded = (Base64.strict_decode64(message) rescue Base64.urlsafe_decode64(message)) rescue (return nil)
      envelope = JSON.parse(decoded)["_rails"] rescue (return nil)
      gid = if envelope["data"]
        envelope["data"]
      elsif envelope["message"]
        Base64.decode64(envelope["message"])[%r{gid://campfire/[^/]+/\d+}]
      end
      gid.to_s[%r{\Agid://campfire/User/(\d+)}, 1]&.to_i
    end
  end

  # Bot webhooks: the bots a message is for, posted the message as JSON from a job.
  module Webhooks
    module_function

    def deliver_later(runtime, room, message)
      body = runtime.repo.bodies([ message.id ])[message.id].to_s
      bot_ids =
        if room.direct?
          runtime.db.rows("SELECT users.id FROM users INNER JOIN memberships ON users.id = memberships.user_id WHERE memberships.room_id = ? AND users.status = 0 AND users.role = 2", room.id).map(&:first)
        else
          ids = Mentions.user_ids(body)
          ids.empty? ? [] : runtime.db.rows("SELECT users.id FROM users INNER JOIN memberships ON users.id = memberships.user_id WHERE memberships.room_id = ? AND users.id IN (#{DB.in_list(ids.size)}) AND users.status = 0 AND users.role = 2", room.id, *ids).map(&:first)
        end
      (bot_ids - [ message.creator_id ]).each { |bot_id| Jobs.later(Bots, :deliver, bot_id, message.id) }
    end
  end
end

module Campfire
  # Bot::WebhookJob over Webhook#deliver: posts the message to the bot's webhook and posts the
  # reply (text, or an attachment) back to the room as the bot.
  module Bots
    ENDPOINT_TIMEOUT = 7

    module_function

    def deliver(bot_id, message_id)
      runtime = Jobs.runtime
      ctx = JobContext.new(runtime)
      bot = runtime.repo.user(bot_id) or return
      url = runtime.db.value("SELECT url FROM webhooks WHERE user_id = ? LIMIT 1", bot_id) or return
      message = Message.new(*runtime.db.row("SELECT #{Message.columns} FROM messages WHERE id = ?", message_id))
      room = runtime.repo.room(message.room_id)
      ctx.current_user = bot

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = http.read_timeout = ENDPOINT_TIMEOUT
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
      request.body = payload(ctx, bot, room, message)
      response = http.request(request)

      if response.code == "200" && %w[ text/html text/plain ].include?(response.content_type)
        reply(ctx, room, bot, "body" => String.new(response.body).force_encoding("UTF-8"))
      elsif response.content_type && (extension = MIME_EXTENSIONS[response.content_type])
        file = Tempfile.new([ "attachment", ".#{extension}" ]).tap { it.binmode; it.write(response.body); it.rewind }
        reply(ctx, room, bot, "attachment" => { tempfile: file, filename: "attachment.#{extension}", type: response.content_type })
      end
    rescue Net::OpenTimeout, Net::ReadTimeout
      reply(ctx, room, bot, "body" => "Failed to respond within #{ENDPOINT_TIMEOUT} seconds") if room
    rescue => error
      warn "webhook failed: #{error.class}: #{error.message}"
    end

    MIME_EXTENSIONS = { "image/png" => "png", "image/jpeg" => "jpeg", "image/gif" => "gif", "image/webp" => "webp", "application/pdf" => "pdf",
      "application/json" => "json", "text/csv" => "csv", "application/zip" => "zip" }.freeze

    def reply(ctx, room, bot, params)
      message = Messages.create(ctx, room: room, creator: bot, params: params)
      Messages.after_create(ctx, room, message, Messages.views(ctx, [ message ]).first, webhooks: false)
    end

    def payload(ctx, bot, room, message)
      body = ctx.repo.bodies([ message.id ])[message.id]
      attachment = ctx.repo.message_attachments([ message.id ])[message.id]
      creator = ctx.repo.user(message.creator_id)
      plain = Messages.plain_text_body(ctx, body, attachment).gsub("@#{bot.name}", "").gsub(/\A\p{Space}+|\p{Space}+\z/, "")
      JSON.generate(
        user: { id: creator.id, name: creator.name },
        room: { id: room.id, name: room.name, path: "/rooms/#{room.id}/#{bot.id}-#{bot.bot_token}/messages" },
        message: { id: message.id, body: { html: body.to_s, plain: plain }, path: "/rooms/#{room.id}/@#{message.id}" })
    end
  end

  # What message creation needs outside a request: like a broadcast rendered by
  # ApplicationController.renderer, links use its default host.
  class JobContext
    attr_reader :runtime
    attr_accessor :current_user

    def initialize(runtime)
      @runtime = runtime
    end

    def db = runtime.db
    def repo = runtime.repo
    def base_url = "http://example.org"
    def url_for(path) = "#{base_url}#{path}"

    def build_view(**locals)
      View.new(app: runtime, current_user: current_user, base_url: base_url).with(**locals)
    end
  end
end

module Campfire
  module Maintenance
    module_function

    # What the Rails app does at boot: the database exists (db:prepare) and no membership still
    # counts connections from before the restart (Membership.disconnect_all in config/puma.rb).
    def boot
      db = DB.new
      cutoff = (Time.now.utc - Memberships::CONNECTION_TTL).strftime("%Y-%m-%d %H:%M:%S.%6N")
      db.transaction do |w|
        w.run("UPDATE memberships SET connected_at = NULL, connections = 0, updated_at = ? WHERE connected_at >= ?", TimeFormat.now_text, cutoff)
      end
    end
  end
end

module Campfire
  # AllowBrowser::VERSIONS through ActionController::AllowBrowser::BrowserBlocker
  module Browsers
    VERSIONS = { safari: 17.2, chrome: 120, firefox: 121, opera: 104, ie: false }.freeze

    module_function

    def blocked?(user_agent_string)
      return false if user_agent_string.to_s.empty?
      user_agent = UserAgent.parse(user_agent_string)
      return false if user_agent.version.to_s.empty? || user_agent.bot?
      name = user_agent.browser.to_s.downcase
      name = "ie" if name == "internet explorer"
      return false unless VERSIONS.key?(name.to_sym)
      minimum = VERSIONS[name.to_sym]
      minimum ? user_agent.version < UserAgent::Version.new(minimum.to_s) : true
    end
  end

  # ActionController::RateLimiting over the cache store: a counter per key and window, in Redis
  # so every process shares it.
  module RateLimit
    module_function

    def exceeded?(key, limit:, within:)
      redis_key = "rate-limit:#{key}"
      count = Redis.call("INCR", redis_key)
      Redis.call("EXPIRE", redis_key, within, "NX") if count == 1
      count > limit
    rescue RedisClient::Error
      false
    end
  end

  # The Rails app's Redis (its cache store): one connection per process. RedisClient calls from
  # different fibers mustn't interleave, so each takes a lock.
  module Redis
    LOCK = Mutex.new

    def self.call(*command)
      LOCK.synchronize { client.call(*command) }
    end

    # bin/start runs Redis there unless REDIS_URL says otherwise.
    def self.client
      @client = nil unless @client_pid == Process.pid
      @client_pid = Process.pid
      @client ||= RedisClient.config(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")).new_client
    end
  end

  # User creation: joining with the account's code, and the first run's administrator.
  module Users
    module_function

    def create(ctx, attributes, role: 0)
      now = TimeFormat.now_text
      digest = BCrypt::Password.create(attributes["password"].to_s, cost: BCrypt::Engine::DEFAULT_COST)
      # Stored as typed: the reference doesn't normalize email addresses, and signs in by an exact match.
      email = attributes["email_address"].to_s
      user_id = ctx.db.transaction do |w|
        next nil if w.value("SELECT 1 FROM users WHERE email_address = ?", email)
        w.run("INSERT INTO users (created_at, email_address, name, password_digest, role, status, updated_at) VALUES (?, ?, ?, ?, ?, 0, ?)",
          now, email, attributes["name"].to_s, digest, role, now)
        id = w.last_insert_row_id
        yield w, id if block_given?
        # User#grant_membership_to_open_rooms
        w.rows("SELECT id FROM rooms WHERE type = 'Rooms::Open'").each do |(room_id)|
          w.run("INSERT OR IGNORE INTO memberships (created_at, room_id, updated_at, user_id) VALUES (?, ?, ?, ?)", now, room_id, now, id)
        end
        id
      end
      return nil unless user_id
      attach_avatar(ctx, user_id, attributes["avatar"])
      ctx.repo.user(user_id)
    end

    # FirstRun.create!: the account, the first open room and its administrator.
    def first_run(ctx, attributes)
      create(ctx, attributes, role: 1) do |w, user_id|
        now = TimeFormat.now_text
        join_code = SecureRandom.alphanumeric(12).scan(/.{4}/).join("-")
        w.run("INSERT INTO accounts (created_at, join_code, name, singleton_guard, updated_at) VALUES (?, ?, 'Campfire', 0, ?)", now, join_code, now)
        w.run("INSERT INTO rooms (created_at, creator_id, name, type, updated_at) VALUES (?, ?, 'All Talk', 'Rooms::Open', ?)", now, user_id, now)
        room_id = w.last_insert_row_id
        w.run("INSERT OR IGNORE INTO memberships (created_at, involvement, room_id, updated_at, user_id) VALUES (?, 'mentions', ?, ?, ?)", now, room_id, now, user_id)
      end
    end

    def attach_avatar(ctx, user_id, upload)
      return unless upload.is_a?(Hash) && upload[:tempfile]
      blob = Uploads.store(ctx, upload)
      ctx.db.transaction { |w| Uploads.attach(w, blob, "User", user_id, "avatar", TimeFormat.now_text) }
      Uploads.analyze(ctx, blob)
    end
  end
end

module Campfire
  module Profiles
    module_function

    # Users::ProfilesController#update: blank fields are left alone (`.compact` drops only nils,
    # and the form sends every field, so an empty password is ignored by has_secure_password).
    def update(ctx, user, attributes)
      now = TimeFormat.now_text
      ctx.db.transaction do |w|
        w.run("UPDATE users SET name = ?, updated_at = ? WHERE id = ?", attributes["name"], now, user.id) if attributes.key?("name") && !attributes["name"].to_s.empty?
        w.run("UPDATE users SET email_address = ?, updated_at = ? WHERE id = ?", attributes["email_address"].to_s, now, user.id) if attributes.key?("email_address")
        w.run("UPDATE users SET bio = ?, updated_at = ? WHERE id = ?", attributes["bio"], now, user.id) if attributes.key?("bio")
        unless attributes["password"].to_s.empty?
          w.run("UPDATE users SET password_digest = ?, updated_at = ? WHERE id = ?", BCrypt::Password.create(attributes["password"]).to_s, now, user.id)
        end
      end
      if attributes["avatar"].is_a?(Hash)
        remove_avatar(ctx, user)
        Users.attach_avatar(ctx, user.id, attributes["avatar"])
        ctx.db.transaction { |w| w.run("UPDATE users SET updated_at = ? WHERE id = ?", TimeFormat.now_text, user.id) }
      end
    end

    def remove_avatar(ctx, user)
      ctx.db.transaction do |w|
        w.run("DELETE FROM active_storage_attachments WHERE record_type = 'User' AND record_id = ? AND name = 'avatar'", user.id)
        w.run("UPDATE users SET updated_at = ? WHERE id = ?", TimeFormat.now_text, user.id)
      end
    end
  end

  # User::Bannable
  module Bans
    module_function

    # False, with nothing changed, when a session's address can't be banned: bans.create! raises
    # RecordInvalid inside the ban's transaction, which rolls it back.
    def ban(ctx, user)
      now = TimeFormat.now_text
      banned = ctx.db.transaction do |w|
        ips = w.rows("SELECT DISTINCT ip_address FROM sessions WHERE user_id = ? AND ip_address IS NOT NULL AND ip_address != ''", user.id).map(&:first)
        next false unless ips.all? { bannable_ip?(it) }
        ips.each { w.run("INSERT INTO bans (created_at, ip_address, updated_at, user_id) VALUES (?, ?, ?, ?)", now, it, now, user.id) }
        w.run("DELETE FROM sessions WHERE user_id = ?", user.id)
        w.run("UPDATE users SET status = 2, updated_at = ? WHERE id = ?", now, user.id)
        true
      end
      return false unless banned
      Broadcasts.disconnect_user(user.id)
      Jobs.later(Bans, :remove_banned_content, user.id)
      true
    end

    # Ban#ip_address_is_public
    def bannable_ip?(ip)
      address = IPAddr.new(ip)
      !(address.loopback? || address.private? || address.link_local?)
    rescue IPAddr::InvalidAddressError
      false
    end

    def unban(ctx, user)
      ctx.db.transaction do |w|
        w.run("DELETE FROM bans WHERE user_id = ?", user.id)
        w.run("UPDATE users SET status = 0, updated_at = ? WHERE id = ?", TimeFormat.now_text, user.id)
      end
    end

    # RemoveBannedContentJob: each message destroyed and its removal broadcast.
    def remove_banned_content(user_id)
      runtime = Jobs.runtime
      runtime.db.rows("SELECT #{Message.columns} FROM messages WHERE creator_id = ?", user_id).each do |row|
        message = Message.new(*row)
        room = runtime.repo.room(message.room_id)
        MessageRemoval.destroy(runtime, message)
        Broadcasts.turbo_stream("#{RailsCompat.gid_param(room.type, room.id)}:messages", %(<turbo-stream action="remove" target="message_#{message.client_message_id}"></turbo-stream>))
      end
    end
  end

  module MessageRemoval
    module_function

    # Message destroy: boosts, the rich text, the attachment and the search index row go with it.
    def destroy(runtime, message)
      runtime.db.transaction do |w|
        w.run("DELETE FROM boosts WHERE message_id = ?", message.id)
        w.run("DELETE FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = ?", message.id)
        w.run("DELETE FROM active_storage_attachments WHERE record_type = 'Message' AND record_id = ?", message.id)
        w.run("DELETE FROM message_search_index WHERE rowid = ?", message.id)
        w.run("DELETE FROM messages WHERE id = ?", message.id)
        w.run("UPDATE rooms SET updated_at = ? WHERE id = ?", TimeFormat.now_text, message.room_id)
      end
    end
  end

  module Involvements
    module_function

    # Rooms::InvolvementsController#update and its sidebar broadcasts
    def update(ctx, membership, involvement)
      return unless %w[ invisible nothing mentions everything ].include?(involvement)
      ctx.db.transaction { |w| w.run("UPDATE memberships SET involvement = ?, updated_at = ? WHERE id = ?", involvement, TimeFormat.now_text, membership.id) }
      room = ctx.repo.room(membership.room_id)
      return if room.direct?
      stream = "#{RailsCompat.gid_param("User", membership.user_id)}:rooms"
      if involvement == "invisible"
        Broadcasts.turbo_stream(stream, %(<turbo-stream action="remove" target="list_#{room.param_key}_#{room.id}"></turbo-stream>))
      elsif membership.involvement == "invisible"
        html = %(<a id="list_#{room.param_key}_#{room.id}" data-rooms-list-target="room" data-room-id="#{room.id}" data-badge-dot-target="unread" data-sorted-list-target="item" data-sorted-list-name="#{HTML.h(room.name)}" style="--column-gap: 0.5em" class="align-center gap room btn txt-nowrap" href="/rooms/#{room.id}">\n  <span class="overflow-ellipsis">#{HTML.h(room.name)}</span>\n</a>)
        Broadcasts.turbo_stream(stream, %(<turbo-stream action="prepend" target="shared_rooms"><template>#{html}</template></turbo-stream>))
      end
    end
  end
end

module Campfire
  module Boosts
    module_function

    # The full content, as Rails stores it: SQLite doesn't enforce the column's limit: 16, and the
    # Boost model doesn't validate it.
    def create(ctx, message, content)
      now = TimeFormat.now_text
      boost = ctx.db.transaction do |w|
        w.run("INSERT INTO boosts (booster_id, content, created_at, message_id, updated_at) VALUES (?, ?, ?, ?, ?)",
          ctx.current_user.id, content, now, message.id, now)
        id = w.last_insert_row_id
        w.run("UPDATE messages SET updated_at = ? WHERE id = ?", now, message.id)
        Boost.new(id, ctx.current_user.id, content, now, message.id, now)
      end
      room = ctx.repo.room(message.room_id)
      html = ctx.build_view.render_boost(boost, ctx.current_user)
      Broadcasts.turbo_stream("#{RailsCompat.gid_param(room.type, room.id)}:messages",
        %(<turbo-stream maintain_scroll="true" action="append" target="boosts_message_#{message.client_message_id}"><template>#{html}</template></turbo-stream>))
      boost
    end

    def destroy(ctx, message, id)
      deleted = ctx.db.transaction do |w|
        next false unless w.value("SELECT 1 FROM boosts WHERE id = ? AND message_id = ? AND booster_id = ?", id, message.id, ctx.current_user.id)
        w.run("DELETE FROM boosts WHERE id = ?", id)
        w.run("UPDATE messages SET updated_at = ? WHERE id = ?", TimeFormat.now_text, message.id)
        true
      end
      return false unless deleted
      room = ctx.repo.room(message.room_id)
      Broadcasts.turbo_stream("#{RailsCompat.gid_param(room.type, room.id)}:messages", %(<turbo-stream action="remove" target="boost_#{id}"></turbo-stream>))
      true
    end
  end
end

module Campfire
  # Room creation, conversion between open and closed, direct rooms and deletion, with the
  # sidebar broadcasts the Rails controllers send.
  module Rooms
    module_function

    def shared_html(room)
      %(<a id="list_#{room.param_key}_#{room.id}" data-rooms-list-target="room" data-room-id="#{room.id}" data-badge-dot-target="unread" data-sorted-list-target="item" data-sorted-list-name="#{HTML.h(room.name)}" style="--column-gap: 0.5em" class="align-center gap room btn txt-nowrap" href="/rooms/#{room.id}">\n  <span class="overflow-ellipsis">#{HTML.h(room.name)}</span>\n</a>)
    end

    def user_stream(user_id) = "#{RailsCompat.gid_param("User", user_id)}:rooms"

    def create(ctx, type, name, user_ids)
      now = TimeFormat.now_text
      creator = ctx.current_user
      grantees = type == "Rooms::Open" ? [ creator.id ] : user_ids.map(&:to_i).select { ctx.repo.user(it) }
      room = ctx.db.transaction do |w|
        w.run("INSERT INTO rooms (created_at, creator_id, name, type, updated_at) VALUES (?, ?, ?, ?, ?)", now, creator.id, name, type, now)
        id = w.last_insert_row_id
        grantees.each { w.run("INSERT OR IGNORE INTO memberships (created_at, involvement, room_id, updated_at, user_id) VALUES (?, 'mentions', ?, ?, ?)", now, id, now, it) }
        if type == "Rooms::Open" # Rooms::Open#grant_access_to_all_users
          w.rows("SELECT id FROM users WHERE status = 0").each { |(uid)| w.run("INSERT OR IGNORE INTO memberships (created_at, room_id, updated_at, user_id) VALUES (?, ?, ?, ?)", now, id, now, uid) }
        end
        Room.new(id, now, creator.id, name, type, now)
      end
      broadcast_created(ctx, room)
      room
    end

    def broadcast_created(ctx, room)
      html = shared_html(room)
      if room.open?
        Broadcasts.turbo_stream("rooms", %(<turbo-stream action="prepend" target="shared_rooms"><template>#{html}</template></turbo-stream>))
      else
        ctx.repo.room_user_ids(room.id).each { Broadcasts.turbo_stream(user_stream(it), %(<turbo-stream action="prepend" target="shared_rooms"><template>#{html}</template></turbo-stream>)) }
      end
    end

    def update(ctx, room, type, name, user_ids)
      now = TimeFormat.now_text
      revoked = []
      ctx.db.transaction do |w|
        # update! touches updated_at only when the name or type changes
        w.run("UPDATE rooms SET name = COALESCE(?, name), type = ?, updated_at = ? WHERE id = ? AND (name IS NOT COALESCE(?, name) OR type != ?)",
          name, type, now, room.id, name, type)
        if type == "Rooms::Closed"
          grantees = user_ids.map(&:to_i)
          current = w.rows("SELECT user_id FROM memberships WHERE room_id = ?", room.id).map(&:first)
          (grantees - current).each { w.run("INSERT OR IGNORE INTO memberships (created_at, involvement, room_id, updated_at, user_id) VALUES (?, 'mentions', ?, ?, ?)", now, room.id, now, it) }
          revoked = current - grantees
          revoked.each { w.run("DELETE FROM memberships WHERE room_id = ? AND user_id = ?", room.id, it) }
        elsif room.type != "Rooms::Open"
          w.rows("SELECT id FROM users WHERE status = 0").each { |(uid)| w.run("INSERT OR IGNORE INTO memberships (created_at, room_id, updated_at, user_id) VALUES (?, ?, ?, ?)", now, room.id, now, uid) }
        end
      end
      # Membership's after_destroy_commit: user.reset_remote_connections
      revoked.each { Broadcasts.disconnect_user(it, reconnect: true) }
      room = ctx.repo.room(room.id)
      html = shared_html(room)
      replace = %(<turbo-stream action="replace" target="list_#{room.param_key}_#{room.id}"><template>#{html}</template></turbo-stream>)
      if room.open?
        Broadcasts.turbo_stream("rooms", replace)
      else
        ctx.repo.room_user_ids(room.id).each { Broadcasts.turbo_stream(user_stream(it), replace) }
      end
      room
    end

    # Rooms::Direct.find_or_create_for: the direct room whose members are exactly these users.
    def find_or_create_direct(ctx, user_ids)
      user_ids = user_ids.select { ctx.repo.user(it) }.sort
      existing = ctx.repo.direct_room_ids(ctx.current_user.id).find { ctx.repo.room_user_ids(it).sort == user_ids }
      return ctx.repo.room(existing) if existing

      now = TimeFormat.now_text
      room = ctx.db.transaction do |w|
        w.run("INSERT INTO rooms (created_at, creator_id, name, type, updated_at) VALUES (?, ?, NULL, 'Rooms::Direct', ?)", now, ctx.current_user.id, now)
        id = w.last_insert_row_id
        user_ids.each { w.run("INSERT OR IGNORE INTO memberships (created_at, involvement, room_id, updated_at, user_id) VALUES (?, 'everything', ?, ?, ?)", now, id, now, it) }
        Room.new(id, now, ctx.current_user.id, nil, "Rooms::Direct", now)
      end
      memberships = ctx.db.rows("SELECT #{Membership.columns} FROM memberships WHERE room_id = ?", room.id).map { Membership.new(*it) }
      memberships.each do |membership|
        user = ctx.repo.user(membership.user_id)
        members = ctx.repo.room_users_except(room.id, user.id)
        members = [ user ] if members.empty?
        html = ctx.build_view.render_sidebar_direct(membership, room, members)
        Broadcasts.turbo_stream(user_stream(user.id), %(<turbo-stream action="prepend" target="direct_rooms"><template>#{html}</template></turbo-stream>))
      end
      room
    end

    def destroy(ctx, room)
      ctx.db.transaction do |w|
        ids = w.rows("SELECT id FROM messages WHERE room_id = ?", room.id).map(&:first)
        ids.each_slice(500) do |slice|
          list = DB.in_list(slice.size)
          w.run("DELETE FROM boosts WHERE message_id IN (#{list})", *slice)
          w.run("DELETE FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id IN (#{list})", *slice)
          w.run("DELETE FROM active_storage_attachments WHERE record_type = 'Message' AND record_id IN (#{list})", *slice)
          w.run("DELETE FROM message_search_index WHERE rowid IN (#{list})", *slice)
        end
        w.run("DELETE FROM messages WHERE room_id = ?", room.id)
        w.run("DELETE FROM memberships WHERE room_id = ?", room.id)
        w.run("DELETE FROM rooms WHERE id = ?", room.id)
      end
      Broadcasts.turbo_stream("rooms", %(<turbo-stream action="remove" target="list_#{room.param_key}_#{room.id}"></turbo-stream>))
    end
  end
end

module Campfire
  module Accounts
    module_function

    def update(ctx, attributes)
      now = TimeFormat.now_text
      account = ctx.runtime.account
      ctx.db.transaction do |w|
        w.run("UPDATE accounts SET name = ?, updated_at = ? WHERE id = ?", attributes["name"], now, account.id) if attributes["name"]
        if (settings = attributes["settings"]).is_a?(Hash)
          current = (JSON.parse(account.settings.to_s) rescue {}) || {}
          value = settings["restrict_room_creation_to_administrators"]
          current["restrict_room_creation_to_administrators"] = value == "true" if value
          w.run("UPDATE accounts SET settings = ?, updated_at = ? WHERE id = ?", JSON.generate(current), now, account.id)
        end
      end
      if attributes["logo"].is_a?(Hash) && attributes["logo"][:tempfile]
        blob = Uploads.store(ctx, attributes["logo"])
        ctx.db.transaction do |w|
          w.run("DELETE FROM active_storage_attachments WHERE record_type = 'Account' AND name = 'logo'")
          Uploads.attach(w, blob, "Account", account.id, "logo", now)
          w.run("UPDATE accounts SET updated_at = ? WHERE id = ?", TimeFormat.now_text, account.id)
        end
        Uploads.analyze(ctx, blob)
      end
    end

    # User#deactivate
    def deactivate(ctx, user)
      ctx.db.transaction do |w|
        w.run("DELETE FROM memberships WHERE user_id = ? AND room_id IN (SELECT id FROM rooms WHERE type != 'Rooms::Direct')", user.id)
        w.run("DELETE FROM push_subscriptions WHERE user_id = ?", user.id)
        w.run("DELETE FROM searches WHERE user_id = ?", user.id)
        w.run("DELETE FROM sessions WHERE user_id = ?", user.id)
        email = user.email_address&.sub("@", "-deactivated-#{SecureRandom.uuid}@")
        w.run("UPDATE users SET status = 1, email_address = ?, updated_at = ? WHERE id = ?", email, TimeFormat.now_text, user.id)
      end
      Broadcasts.disconnect_user(user.id)
    end
  end
end

module Campfire
  # User.create_bot! and User#update_bot!
  module BotAccounts
    module_function

    def create(ctx, attributes)
      now = TimeFormat.now_text
      id = ctx.db.transaction do |w|
        w.run("INSERT INTO users (bot_token, created_at, name, role, status, updated_at) VALUES (?, ?, ?, 2, 0, ?)",
          SecureRandom.alphanumeric(12), now, attributes["name"].to_s, now)
        id = w.last_insert_row_id
        url = attributes["webhook_url"].to_s
        w.run("INSERT INTO webhooks (created_at, updated_at, url, user_id) VALUES (?, ?, ?, ?)", now, now, url, id) unless url.empty?
        w.rows("SELECT id FROM rooms WHERE type = 'Rooms::Open'").each { |(room_id)| w.run("INSERT OR IGNORE INTO memberships (created_at, room_id, updated_at, user_id) VALUES (?, ?, ?, ?)", now, room_id, now, id) }
        id
      end
      Users.attach_avatar(ctx, id, attributes["avatar"])
    end

    def update(ctx, bot, attributes)
      now = TimeFormat.now_text
      ctx.db.transaction do |w|
        url = attributes["webhook_url"].to_s
        if url.empty?
          w.run("DELETE FROM webhooks WHERE user_id = ?", bot.id)
        elsif w.value("SELECT 1 FROM webhooks WHERE user_id = ?", bot.id)
          w.run("UPDATE webhooks SET url = ?, updated_at = ? WHERE user_id = ?", url, now, bot.id)
        else
          w.run("INSERT INTO webhooks (created_at, updated_at, url, user_id) VALUES (?, ?, ?, ?)", now, now, url, bot.id)
        end
        w.run("UPDATE users SET name = ?, updated_at = ? WHERE id = ?", attributes["name"], now, bot.id) if attributes["name"]
      end
      if attributes["avatar"].is_a?(Hash)
        Profiles.remove_avatar(ctx, bot)
        Users.attach_avatar(ctx, bot.id, attributes["avatar"])
      end
    end
  end
end

module Campfire
  module Autocomplete
    module_function

    def users(ctx, room_id, query)
      scope = if room_id.to_s.empty?
        "SELECT #{User.columns} FROM users WHERE users.status = 0"
      else
        room = ctx.repo.user_room(ctx.current_user.id, room_id.to_i) or ctx.halt(404)
        "SELECT #{User.columns} FROM users INNER JOIN memberships ON users.id = memberships.user_id WHERE memberships.room_id = #{room.id} AND users.status = 0"
      end
      sql = query.empty? ? "#{scope} ORDER BY LOWER(name) LIMIT 20" : "#{scope} AND (name like ?) ORDER BY LOWER(name) LIMIT 20"
      ctx.db.rows(sql, *("%#{query}%" unless query.empty?)).map { User.new(*it) }
    end

    def prompt_item(view, user)
      sgid = view.secrets.attachable_sgid("User", user.id)
      mention = %(<span class="mention" sgid="#{sgid}">#{view.avatar_tag(user)} #{HTML.h(user.name)}</span>)
      <<~HTML
        <lexxy-prompt-item search="#{HTML.h(user.name)}" sgid="#{sgid}">
          <template type="menu">
            <span class="autocomplete__item flex align-center gap unpad">
              #{view.avatar_tag(user)}
              <span class="autocompletable__name">#{HTML.h(user.name)}</span>
            </span>
          </template>
          <template type="editor">
            #{mention}
          </template>
        </lexxy-prompt-item>
      HTML
    end
  end

  module Pwa
    module_function

    # pwa/manifest.json.erb as Rails renders it: the small logo's URL is HTML-escaped (`&amp;`) inside
    # the JSON, as ERB escapes it.
    def manifest(view, account, base_url)
      logo = view.account_logo_path
      <<~JSON
        {
          "name": #{JSON.generate(account&.name || "Campfire")},
          "icons": [
            {
              "src": "#{logo.include?("?") ? logo.sub("?", "?size=small&amp;") : "#{logo}?size=small"}",
              "type": "image/png",
              "sizes": "192x192"
            },
            {
              "src": "#{logo}",
              "type": "image/png",
              "sizes": "512x512"
            },
            {
              "src": "#{logo}",
              "type": "image/png",
              "sizes": "512x512",
              "purpose": "maskable"
            }
          ],
          "start_url": "/",
          "display": "standalone",
          "scope": "/",
          "description": "A chat app from the makers of Basecamp and HEY.",
          "categories": ["social", "business", "productivity"],
          "theme_color": "#ffffff",
          "background_color": "#ffffff",
          "shortcuts": [
            {
              "name": "New chat room",
              "description": "Open Campfire and start a new chat room",
              "url": "rooms/opens/new",
              "icons": [{ "src": "#{base_url}#{Assets.path("add.svg")}", "sizes": "any" }]
            },
            {
              "name": "My profile",
              "description": "Open Campfire and view your profile",
              "url": "/users/me/profile",
              "icons": [{ "src": "#{base_url}#{Assets.path("person.svg")}", "sizes": "any" }]
            }
          ],
          "screenshots": [
            {
              "src": "#{base_url}#{Assets.path("screenshots/android-chat.png")}",
              "sizes": "1080x2400",
              "form_factor": "narrow",
              "label": "Campfire is an installable, self-hosted group chat system."
            },
            {
              "src": "#{base_url}#{Assets.path("screenshots/android-sidebar.png")}",
              "sizes": "1080x2400",
              "form_factor": "narrow",
              "label": "Easily invite people. Make rooms. @mentions, DMs, and mobile support."
            },
            {
              "src": "#{base_url}#{Assets.path("screenshots/android-dark-mode.png")}",
              "sizes": "1080x2400",
              "form_factor": "narrow",
              "label": "Full support for dark mode, customizable to your brand."
            }
          ]
        }
      JSON
    end
  end

  module PushSubscriptions
    module_function

    def create(ctx, attributes)
      endpoint, p256dh, auth = attributes.values_at("endpoint", "p256dh_key", "auth_key")
      return false unless Push.permitted?(endpoint)
      now = TimeFormat.now_text
      ctx.db.transaction do |w|
        if (id = w.value("SELECT id FROM push_subscriptions WHERE user_id = ? AND endpoint = ? AND p256dh_key = ? AND auth_key = ?", ctx.current_user.id, endpoint, p256dh, auth))
          w.run("UPDATE push_subscriptions SET updated_at = ? WHERE id = ?", now, id)
        else
          w.run("INSERT INTO push_subscriptions (auth_key, created_at, endpoint, p256dh_key, updated_at, user_agent, user_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
            auth, now, endpoint, p256dh, now, ctx.request.user_agent, ctx.current_user.id)
        end
      end
      true
    end
  end

  # The bot API's JSON (messages/_message.json.jbuilder, users/_user.json.jbuilder)
  module BotApi
    module_function

    def message_json(ctx, message)
      repo = ctx.repo
      body = repo.bodies([ message.id ])[message.id]
      attachment = repo.message_attachments([ message.id ])[message.id]
      creator = repo.user(message.creator_id)
      html = body ? %(<div class="lexxy-content">\n  #{RichText.sanitizer.sanitize(RichText.render_attachments(body, ->(node) { Attachments.render(ctx, node) }), tags: RichText::ACTION_TEXT_TAGS, attributes: RichText::ACTION_TEXT_ATTRIBUTES)}\n</div>\n) : ""
      {
        id: message.id,
        created_at: TimeFormat.parse(message.created_at).strftime("%Y-%m-%dT%H:%M:%S.%LZ"),
        body: { plain_text: Messages.plain_text_body(ctx, body, attachment), html: html },
        creator: user_json(ctx, creator),
        room: { id: message.room_id },
        url: ctx.url_for("/rooms/#{message.room_id}/messages/#{message.id}")
      }
    end

    # messages/boosts/_boost.json
    def boost_json(ctx, boost, message)
      booster = ctx.repo.user(boost.booster_id)
      {
        id: boost.id,
        content: boost.content,
        created_at: TimeFormat.parse(boost.created_at).strftime("%Y-%m-%dT%H:%M:%S.%LZ"),
        booster: user_json(ctx, booster),
        message: { id: message.id, url: ctx.url_for("/rooms/#{message.room_id}/messages/#{message.id}") }
      }
    end

    # users/_user.json
    def user_json(ctx, user)
      { id: user.id, name: user.name, role: user.role_name, avatar_url: ctx.url_for(ctx.build_view.avatar_path(user)) }
    end

    def next_page_link(ctx, room, bot_key, messages)
      return nil if messages.empty?
      if !ctx.params["after"].to_s.empty?
        last = messages.last
        more = ctx.db.value("SELECT 1 FROM messages WHERE room_id = ? AND created_at > ? LIMIT 1", room.id, last.created_at)
        more && %(<#{ctx.url_for("/rooms/#{room.id}/#{bot_key}/messages?after=#{last.id}")}>; rel="next")
      else
        first = messages.first
        more = ctx.db.value("SELECT 1 FROM messages WHERE room_id = ? AND created_at < ? LIMIT 1", room.id, first.created_at)
        more && %(<#{ctx.url_for("/rooms/#{room.id}/#{bot_key}/messages?before=#{first.id}")}>; rel="next")
      end
    end
  end
end
