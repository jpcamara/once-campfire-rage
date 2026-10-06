class DirectsController < ApplicationController
  action :new do
    require_authentication!
    view = build_view
    render_layout(view, main: view.tpl_rooms_direct_new)
  end

  action :create do
    verify_same_origin!
    require_authentication!
    room = Rooms.find_or_create_direct(self, (Array(params["user_ids"]).map(&:to_i) + [ current_user.id ]).uniq)
    redirect url_for("/rooms/#{room.id}")
  end

  action :edit do
    id = id_param("id")
    require_authentication!
    room = repo.user_room(current_user.id, id)
    return redirect_with_alert("/", "Room not found or inaccessible") unless room&.direct?
    users = repo.room_users(room.id)
    members = users.size > 1 ? users.reject { it.id == current_user.id } : users
    view = build_view(room: room, members: members, last_room_visited: last_room_visited)
    render_layout(view, page_title: "Edit settings for #{view.room_display_name(room)}", nav: view.tpl_rooms_settings_nav, main: view.tpl_rooms_direct_edit)
  end

  action :show do
    id = id_param("id")
    require_authentication!
    room = repo.user_room(current_user.id, id)
    return redirect_with_alert("/", "Room not found or inaccessible") unless room&.direct?
    redirect url_for("/rooms/#{room.id}")
  end
end
