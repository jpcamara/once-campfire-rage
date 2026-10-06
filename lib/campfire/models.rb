module Campfire
  ROLES = %w[ member administrator bot ].freeze
  STATUSES = %w[ active deactivated banned ].freeze

  User = Data.define(:id, :bio, :bot_token, :created_at, :email_address, :name, :password_digest, :role, :status, :updated_at) do
    def self.columns = "users.id, users.bio, users.bot_token, users.created_at, users.email_address, users.name, users.password_digest, users.role, users.status, users.updated_at"

    def administrator? = role == 1
    def bot? = role == 2
    def member? = role == 0
    def active? = status == 0
    def role_name = ROLES[role]

    def title
      [ name, bio ].reject { it.nil? || it.strip.empty? }.join(" – ")
    end

    def initials
      name.scan(/\b\w/).join
    end

    def can_administer?(record = nil)
      administrator? || (record && record.creator_id == id)
    end

    def to_param = id.to_s
  end

  Room = Data.define(:id, :created_at, :creator_id, :name, :type, :updated_at) do
    def self.columns = "rooms.id, rooms.created_at, rooms.creator_id, rooms.name, rooms.type, rooms.updated_at"

    def direct? = type == "Rooms::Direct"
    def open? = type == "Rooms::Open"
    def closed? = type == "Rooms::Closed"

    # ActiveModel::Name#param_key: "rooms_closed"
    def param_key = type.sub("::", "_").downcase
    # Route segment for the room's type controller: /rooms/closeds/:id
    def type_route = "#{type.split("::").last.downcase}s"
    def default_involvement = direct? ? "everything" : "mentions"
  end

  Message = Data.define(:id, :client_message_id, :created_at, :creator_id, :room_id, :updated_at) do
    def self.columns = "messages.id, messages.client_message_id, messages.created_at, messages.creator_id, messages.room_id, messages.updated_at"

    # dom_id uses to_key, which is [client_message_id]
    def dom_key = client_message_id
  end

  Membership = Data.define(:id, :connected_at, :connections, :created_at, :involvement, :room_id, :unread_at, :updated_at, :user_id) do
    def self.columns = "memberships.id, memberships.connected_at, memberships.connections, memberships.created_at, memberships.involvement, memberships.room_id, memberships.unread_at, memberships.updated_at, memberships.user_id"

    def unread? = !unread_at.nil?
  end

  Boost = Data.define(:id, :booster_id, :content, :created_at, :message_id, :updated_at) do
    def self.columns = "boosts.id, boosts.booster_id, boosts.content, boosts.created_at, boosts.message_id, boosts.updated_at"
  end

  Session = Data.define(:id, :created_at, :ip_address, :last_active_at, :token, :updated_at, :user_agent, :user_id) do
    def self.columns = "sessions.id, sessions.created_at, sessions.ip_address, sessions.last_active_at, sessions.token, sessions.updated_at, sessions.user_agent, sessions.user_id"
  end

  Account = Data.define(:id, :created_at, :custom_styles, :join_code, :name, :settings, :singleton_guard, :updated_at) do
    def self.columns = "accounts.id, accounts.created_at, accounts.custom_styles, accounts.join_code, accounts.name, accounts.settings, accounts.singleton_guard, accounts.updated_at"

    def restrict_room_creation_to_administrators?
      parsed = settings && (JSON.parse(settings) rescue nil)
      parsed.is_a?(Hash) && parsed["restrict_room_creation_to_administrators"] == true
    end
  end

  Blob = Data.define(:id, :byte_size, :checksum, :content_type, :created_at, :filename, :key, :metadata, :service_name) do
    def self.columns = "active_storage_blobs.id, active_storage_blobs.byte_size, active_storage_blobs.checksum, active_storage_blobs.content_type, active_storage_blobs.created_at, active_storage_blobs.filename, active_storage_blobs.key, active_storage_blobs.metadata, active_storage_blobs.service_name"

    def parsed_metadata
      @parsed_metadata ||= (metadata && JSON.parse(metadata) rescue {}) || {}
    end

    def image? = content_type.to_s.start_with?("image")
    def video? = content_type.to_s.start_with?("video")
  end
end
