class TypingNotificationsChannel < RoomChannel
  PREFIX = "typing_notifications"

  def start(_data)
    broadcast_typing("start")
  end

  def stop(_data)
    broadcast_typing("stop")
  end

  private
    def broadcast_typing(action)
      Broadcasts.json("#{PREFIX}:#{RailsCompat.gid_param(@room.type, @room.id)}", { action: action, user: { id: current_user.id, name: current_user.name } })
    end
end
