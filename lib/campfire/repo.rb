module Campfire
  # The queries the Rails app runs, in the same SQL shapes (so SQLite returns rows in the same
  # order where Rails leaves the order to the database).
  class Repo
    PAGE_SIZE = 40

    MessageView = Data.define(:message, :creator, :room, :presentation, :attachment, :boosts, :emoji)

    def initialize(db)
      @db = db
    end

    attr_reader :db

    def account
      row = @db.row("SELECT #{Account.columns} FROM accounts ORDER BY accounts.id ASC LIMIT 1")
      row && Account.new(*row)
    end

    def attachment_blob(record_type, record_id, name)
      row = @db.row(<<~SQL, record_id, record_type, name)
        SELECT #{Blob.columns} FROM active_storage_attachments
        JOIN active_storage_blobs ON active_storage_blobs.id = active_storage_attachments.blob_id
        WHERE active_storage_attachments.record_id = ? AND active_storage_attachments.record_type = ? AND active_storage_attachments.name = ? LIMIT 1
      SQL
      row && Blob.new(*row)
    end

    def session_by_token(token)
      row = @db.row("SELECT #{Session.columns} FROM sessions WHERE sessions.token = ? LIMIT 1", token)
      row && Session.new(*row)
    end

    def user(id)
      row = @db.row("SELECT #{User.columns} FROM users WHERE users.id = ? LIMIT 1", id)
      row && User.new(*row)
    end

    def users(ids)
      return {} if ids.empty?
      @db.rows("SELECT #{User.columns} FROM users WHERE users.id IN (#{DB.in_list(ids.size)})", *ids).to_h { [ it[0], User.new(*it) ] }
    end

    def active_user_by_email(email)
      row = @db.row("SELECT #{User.columns} FROM users WHERE users.status = 0 AND users.email_address = ? LIMIT 1", email)
      row && User.new(*row)
    end

    def first_administrator
      row = @db.row("SELECT #{User.columns} FROM users WHERE users.role = 1 ORDER BY users.id ASC LIMIT 1")
      row && User.new(*row)
    end

    def user_room(user_id, room_id)
      row = @db.row(<<~SQL, user_id, room_id)
        SELECT #{Room.columns} FROM rooms INNER JOIN memberships ON rooms.id = memberships.room_id
        WHERE memberships.user_id = ? AND rooms.id = ? LIMIT 1
      SQL
      row && Room.new(*row)
    end

    def membership(user_id, room_id)
      row = @db.row("SELECT #{Membership.columns} FROM memberships WHERE memberships.user_id = ? AND memberships.room_id = ? LIMIT 1", user_id, room_id)
      row && Membership.new(*row)
    end

    def room(id)
      row = @db.row("SELECT #{Room.columns} FROM rooms WHERE rooms.id = ? LIMIT 1", id)
      row && Room.new(*row)
    end

    def rooms(ids)
      return {} if ids.empty?
      @db.rows("SELECT #{Room.columns} FROM rooms WHERE rooms.id IN (#{DB.in_list(ids.size)})", *ids).to_h { [ it[0], Room.new(*it) ] }
    end

    def original_room_id
      @db.value("SELECT rooms.id FROM rooms ORDER BY rooms.created_at ASC LIMIT 1")
    end

    def user_original_room(user_id)
      row = @db.row(<<~SQL, user_id)
        SELECT #{Room.columns} FROM rooms INNER JOIN memberships ON rooms.id = memberships.room_id
        WHERE memberships.user_id = ? ORDER BY rooms.created_at ASC LIMIT 1
      SQL
      row && Room.new(*row)
    end

    def user_last_room(user_id)
      row = @db.row(<<~SQL, user_id)
        SELECT #{Room.columns} FROM rooms INNER JOIN memberships ON rooms.id = memberships.room_id
        WHERE memberships.user_id = ? ORDER BY rooms.id DESC LIMIT 1
      SQL
      row && Room.new(*row)
    end

    def room_message_count(room_id)
      @db.value("SELECT COUNT(*) FROM messages WHERE messages.room_id = ?", room_id)
    end

    def last_page(room_id, size = PAGE_SIZE)
      @db.rows("SELECT #{Message.columns} FROM messages WHERE messages.room_id = ? ORDER BY messages.created_at DESC LIMIT ?", room_id, size)
        .reverse.map { Message.new(*it) }
    end

    def page_before(room_id, created_at)
      @db.rows(<<~SQL, room_id, created_at, PAGE_SIZE).reverse.map { Message.new(*it) }
        SELECT #{Message.columns} FROM messages WHERE messages.room_id = ? AND (created_at < ?) ORDER BY messages.created_at DESC LIMIT ?
      SQL
    end

    def page_after(room_id, created_at)
      @db.rows(<<~SQL, room_id, created_at, PAGE_SIZE).map { Message.new(*it) }
        SELECT #{Message.columns} FROM messages WHERE messages.room_id = ? AND (created_at > ?) ORDER BY messages.created_at ASC LIMIT ?
      SQL
    end

    def messages_created_since(room_id, since)
      @db.rows(<<~SQL, room_id, since, PAGE_SIZE).map { Message.new(*it) }
        SELECT #{Message.columns} FROM messages WHERE messages.room_id = ? AND (created_at > ?) ORDER BY messages.created_at ASC LIMIT ?
      SQL
    end

    def messages_updated_since(room_id, since, excluding)
      excluded = excluding.empty? ? "" : "AND messages.id NOT IN (#{DB.in_list(excluding.size)})"
      @db.rows(<<~SQL, room_id, *excluding, since, PAGE_SIZE).reverse.map { Message.new(*it) }
        SELECT #{Message.columns} FROM messages WHERE messages.room_id = ? #{excluded} AND (updated_at > ?) ORDER BY messages.created_at DESC LIMIT ?
      SQL
    end

    def room_message(room_id, id)
      row = @db.row("SELECT #{Message.columns} FROM messages WHERE messages.room_id = ? AND messages.id = ? LIMIT 1", room_id, id)
      row && Message.new(*row)
    end

    def search(user_id, query, limit = 100)
      @db.rows(<<~SQL, user_id, query, limit).reverse.map { Message.new(*it) }
        SELECT #{Message.columns} FROM messages INNER JOIN rooms ON messages.room_id = rooms.id
        INNER JOIN memberships ON rooms.id = memberships.room_id join message_search_index idx on messages.id = idx.rowid
        WHERE memberships.user_id = ? AND (idx.body match ?) ORDER BY messages.created_at DESC LIMIT ?
      SQL
    end

    def recent_search_queries(user_id)
      @db.rows("SELECT searches.query FROM searches WHERE searches.user_id = ? ORDER BY searches.updated_at DESC", user_id).map(&:first)
    end

    # Rooms' columns under names that don't collide with memberships' in Sequel's row hashes.
    ROOM_COLUMNS_ALIASED = Room.columns.split(", ").map { "#{it} AS #{it.tr(".", "_")}" }.join(", ").freeze

    # Users::SidebarsController#show
    def sidebar_memberships(user_id, visible_only: true)
      @db.rows(<<~SQL, user_id).map { [ Membership.new(*it[0, 9]), Room.new(*it[9, 6]) ] }
        SELECT #{Membership.columns}, #{ROOM_COLUMNS_ALIASED} FROM memberships INNER JOIN rooms ON rooms.id = memberships.room_id
        WHERE memberships.user_id = ? #{"AND memberships.involvement != 'invisible'" if visible_only} ORDER BY LOWER(rooms.name)
      SQL
    end

    def direct_room_ids(user_id)
      @db.rows(<<~SQL, user_id).map(&:first)
        SELECT rooms.id FROM rooms INNER JOIN memberships ON rooms.id = memberships.room_id
        WHERE memberships.user_id = ? AND rooms.type = 'Rooms::Direct'
      SQL
    end

    def member_ids_of_rooms(room_ids)
      return [] if room_ids.empty?
      @db.rows("SELECT memberships.user_id FROM memberships WHERE memberships.room_id IN (#{DB.in_list(room_ids.size)})", *room_ids).map(&:first)
    end

    def room_users_except(room_id, user_id)
      @db.rows(<<~SQL, room_id, user_id).map { User.new(*it) }
        SELECT #{User.columns} FROM users INNER JOIN memberships ON users.id = memberships.user_id
        WHERE memberships.room_id = ? AND users.id != ?
      SQL
    end

    def direct_room_member_names(room_id, user_id)
      @db.rows(<<~SQL, room_id, user_id || -1).map(&:first)
        SELECT users.name FROM users INNER JOIN memberships ON users.id = memberships.user_id
        WHERE memberships.room_id = ? AND users.id != ?
      SQL
    end

    def active_users_ordered
      @db.rows("SELECT #{User.columns} FROM users WHERE users.status = 0 ORDER BY LOWER(name)").map { User.new(*it) }
    end

    def room_user_ids(room_id)
      @db.rows("SELECT users.id FROM users INNER JOIN memberships ON users.id = memberships.user_id WHERE memberships.room_id = ?", room_id).map(&:first)
    end

    def room_users(room_id)
      @db.rows(<<~SQL, room_id).map { User.new(*it) }
        SELECT #{User.columns} FROM users INNER JOIN memberships ON users.id = memberships.user_id WHERE memberships.room_id = ?
      SQL
    end

    def active_users_excluding(ids, limit)
      @db.rows(<<~SQL, *ids, limit).map { User.new(*it) }
        SELECT #{User.columns} FROM users WHERE users.status = 0 AND users.id NOT IN (#{DB.in_list(ids.size)}) ORDER BY users.created_at ASC LIMIT ?
      SQL
    end

    # The per-message data the message partial needs: rich text bodies, attachments with their
    # blobs, and boosts in creation order with their boosters.
    def bodies(message_ids)
      @db.rows(<<~SQL, *message_ids).to_h { [ it[0], it[1] ] }
        SELECT action_text_rich_texts.record_id, action_text_rich_texts.body FROM action_text_rich_texts
        WHERE action_text_rich_texts.record_type = 'Message' AND action_text_rich_texts.name = 'body'
        AND action_text_rich_texts.record_id IN (#{DB.in_list(message_ids.size)})
      SQL
    end

    def message_attachments(message_ids)
      @db.rows(<<~SQL, *message_ids).to_h { [ it[0], Blob.new(*it[1..]) ] }
        SELECT active_storage_attachments.record_id, #{Blob.columns} FROM active_storage_attachments
        JOIN active_storage_blobs ON active_storage_blobs.id = active_storage_attachments.blob_id
        WHERE active_storage_attachments.record_type = 'Message' AND active_storage_attachments.name = 'attachment'
        AND active_storage_attachments.record_id IN (#{DB.in_list(message_ids.size)})
      SQL
    end

    def boosts(message_ids)
      @db.rows(<<~SQL, *message_ids).map { Boost.new(*it) }.group_by(&:message_id)
        SELECT #{Boost.columns} FROM boosts WHERE boosts.message_id IN (#{DB.in_list(message_ids.size)}) ORDER BY boosts.created_at ASC
      SQL
    end
  end
end
