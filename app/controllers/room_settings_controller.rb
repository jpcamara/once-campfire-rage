# Open and closed rooms' new, edit, create and update.
class RoomSettingsController < ApplicationController
  action :new do
    require_authentication!
    head_response(403) unless can_create_rooms?
    render_room_settings(form_type, nil)
  end

  action :edit do
    id = id_param("id")
    require_authentication!
    room = repo.user_room(current_user.id, id)
    return redirect_with_alert("/", "Room not found or inaccessible") unless room && !room.direct?
    render_room_settings(form_type, room)
  end

  action :show do
    id = id_param("id")
    require_authentication!
    room = repo.user_room(current_user.id, id)
    return redirect_with_alert("/", "Room not found or inaccessible") unless room && !room.direct?
    remember_last_room_visited(room)
    redirect url_for("/rooms/#{room.id}")
  end

  action :create do
    require_authentication!
    verify_same_origin!
    head_response(403) unless can_create_rooms?
    room = Rooms.create(self, room_type, (params["room"] || {})["name"].to_s, Array(params["user_ids"]))
    redirect url_for("/rooms/#{room.id}")
  end

  action :update do
    id = id_param("id")
    require_authentication!
    verify_same_origin!
    room = repo.user_room(current_user.id, id)
    return redirect_with_alert("/", "Room not found or inaccessible") unless room && !room.direct?
    head_response(403) unless current_user.can_administer?(room)
    room = Rooms.update(self, room, room_type, (params["room"] || {})["name"], Array(params["user_ids"]))
    redirect url_for("/rooms/#{room.id}")
  end

  private
    def form_type = params["kind"].chomp("s")
    def room_type = params["kind"] == "opens" ? "Rooms::Open" : "Rooms::Closed"
end
