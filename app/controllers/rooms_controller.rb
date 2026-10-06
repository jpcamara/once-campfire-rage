class RoomsController < ApplicationController
  action :root do
    require_authentication!
    room = last_room_visited
    room ? redirect(url_for("/rooms/#{room.id}")) : render_welcome
  end

  action :index do
    require_authentication!
    room = repo.user_last_room(current_user.id)
    redirect url_for("/rooms/#{room.id}")
  end

  action :show do
    room_id = id_param("room_id")
    message_id = id_param("message_id") if params.key?("message_id")
    require_authentication!
    room = repo.user_room(current_user.id, room_id)
    return redirect_with_alert("/", "Room not found or inaccessible") unless room

    remember_last_room_visited(room)
    messages = find_room_messages(room, message_id)
    render_room(room, messages)
  end

  action :destroy do
    id = id_param("id")
    verify_same_origin!
    require_authentication!
    room = repo.user_room(current_user.id, id)
    return redirect_with_alert("/", "Room not found or inaccessible") unless room && (room.direct? == request.path_info.include?("/directs/"))
    head_response(403) unless room.direct? || current_user.can_administer?(room)
    Rooms.destroy(self, room)
    redirect url_for("/")
  end

  action :refresh do
    room_id = id_param("room_id")
    require_authentication!
    # respond_to turbo_stream only
    unless env["HTTP_ACCEPT"].to_s.include?("text/vnd.turbo-stream.html")
      without_security_headers
      without_version_headers
      halt 406, { "content-type" => "text/html; charset=utf-8" }, ""
    end
    room = room_scoped!(room_id)
    since = TimeFormat.dump(Time.at(0, params["since"].to_i, :millisecond))
    created = repo.messages_created_since(room.id, since)
    updated = repo.messages_updated_since(room.id, since, created.map(&:id))
    view = build_view
    html = +""
    html << %(<turbo-stream action="append" target="messages_#{room.param_key}_#{room.id}"><template>#{message_views(created).map { view.render_message_cached(it) }.join}</template></turbo-stream>) if created.any?
    message_views(updated).each do |message_view|
      html << %(<turbo-stream action="replace" target="message_#{message_view.message.client_message_id}"><template>#{view.render_message_cached(message_view)}</template></turbo-stream>)
    end
    html_headers("text/vnd.turbo-stream.html")
    html.empty? ? "\n" : html # the template's trailing newline when there's nothing to send
  end
end
