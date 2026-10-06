class RoomMessagesChannel < ApplicationCable::Channel
  def subscribed
    name = runtime.secrets.verified_stream_name(params[:signed_stream_name].to_s) or return reject
    gid_param, suffix = name.split(":", 2)
    return reject unless suffix == "messages" && (room_id = room_id_from_gid(gid_param)) && user_room(room_id)
    stream_from(name)
  end

  private
    def room_id_from_gid(param)
      gid = Base64.urlsafe_decode64(param) rescue nil
      gid&.match(%r{\Agid://campfire/Rooms::(?:Open|Closed|Direct)/(\d+)\z})&.[](1)
    end
end
