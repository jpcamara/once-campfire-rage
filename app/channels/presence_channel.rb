class PresenceChannel < RoomChannel
  PREFIX = "presence"

  def subscribed
    super
    present unless subscription_rejected?
  end

  def unsubscribed
    absent if @room
  end

  def present
    Memberships.present(runtime, current_user.id, @room.id)
    Broadcasts.json("user_#{current_user.id}_reads", { room_id: @room.id })
  end

  def absent
    Memberships.disconnected(runtime, current_user.id, @room.id)
  end

  def refresh
    Memberships.refresh_connection(runtime, current_user.id, @room.id)
  end
end
