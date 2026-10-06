# A channel for one of the user's rooms, streaming "<prefix>:<room's GlobalID param>".
class RoomChannel < ApplicationCable::Channel
  def subscribed
    @room = user_room(params[:room_id]) or return reject
    stream_from("#{self.class::PREFIX}:#{RailsCompat.gid_param(@room.type, @room.id)}")
  end
end
