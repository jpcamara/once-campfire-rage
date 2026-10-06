module Campfire
  # Membership::Connectable
  module Memberships
    CONNECTION_TTL = 60

    module_function

    def present(runtime, user_id, room_id)
      runtime.db.transaction do |w|
        connected_at, connections = w.row("SELECT connected_at, connections FROM memberships WHERE user_id = ? AND room_id = ?", user_id, room_id)
        count = connected?(connected_at) ? connections + 1 : 1
        w.run("UPDATE memberships SET connections = ?, connected_at = ?, unread_at = NULL WHERE user_id = ? AND room_id = ?",
          count, TimeFormat.now_text, user_id, room_id)
      end
    end

    def disconnected(runtime, user_id, room_id)
      runtime.db.transaction do |w|
        connected_at, connections = w.row("SELECT connected_at, connections FROM memberships WHERE user_id = ? AND room_id = ?", user_id, room_id)
        next if connections.nil?
        now = TimeFormat.now_text
        if connected?(connected_at)
          connections -= 1
          w.run("UPDATE memberships SET connections = ?, updated_at = ? WHERE user_id = ? AND room_id = ?", connections, now, user_id, room_id)
        else
          connections = 0
          w.run("UPDATE memberships SET connections = 0, updated_at = ? WHERE user_id = ? AND room_id = ?", now, user_id, room_id)
        end
        w.run("UPDATE memberships SET connected_at = NULL, updated_at = ? WHERE user_id = ? AND room_id = ?", now, user_id, room_id) if connections < 1
      end
    end

    def refresh_connection(runtime, user_id, room_id)
      runtime.db.transaction do |w|
        connected_at, connections = w.row("SELECT connected_at, connections FROM memberships WHERE user_id = ? AND room_id = ?", user_id, room_id)
        next if connections.nil?
        now = TimeFormat.now_text
        unless connected?(connected_at)
          w.run("UPDATE memberships SET connections = 1, updated_at = ? WHERE user_id = ? AND room_id = ?", now, user_id, room_id)
        end
        w.run("UPDATE memberships SET connected_at = ?, updated_at = ? WHERE user_id = ? AND room_id = ?", now, now, user_id, room_id)
      end
    end

    def connected?(connected_at)
      connected_at && TimeFormat.parse(connected_at) >= Time.now - CONNECTION_TTL
    end
  end
end
