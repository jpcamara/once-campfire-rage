class MessagesController < ApplicationController
  action :index do
    room_id = id_param("room_id")
    require_authentication!
    room = room_scoped!(room_id)
    messages =
      if (before = params["before"]).to_s != ""
        anchor = repo.room_message(room.id, before.to_i) or record_not_found!
        repo.page_before(room.id, anchor.created_at)
      elsif (after = params["after"]).to_s != ""
        anchor = repo.room_message(room.id, after.to_i) or record_not_found!
        repo.page_after(room.id, anchor.created_at)
      else
        repo.last_page(room.id)
      end

    if messages.empty?
      headers "cache-control" => "no-cache"
      status 204
      return ""
    end

    etag_for_messages(messages)
    # fresh_when @messages: the newest updated_at is the Last-Modified.
    headers "last-modified" => messages.map { TimeFormat.parse(it.updated_at) }.max.httpdate
    html_headers
    messages_html(messages)
  end

  action :create do
    room_id = id_param("room_id")
    verify_same_origin!
    require_authentication!
    membership = repo.membership(current_user.id, room_id)
    return render_room_not_found unless membership

    room = repo.room(membership.room_id)
    message = Messages.create(self, room: room, creator: current_user, params: params["message"] || {})
    view = message_views([ message ]).first
    Messages.after_create(self, room, message, view)

    html_headers("text/vnd.turbo-stream.html")
    %(<turbo-stream action="append" target="messages_#{room.param_key}_#{room.id}"><template>#{build_view.render_message_cached(view)}</template></turbo-stream>)
  end

  action :show do
    room_id, id = id_param("room_id"), id_param("id")
    require_authentication!
    room = room_scoped!(room_id)
    message = repo.room_message(room.id, id) or record_not_found!
    view = build_view
    render_layout(view, main: view.render_message_cached(message_views([ message ]).first), frame_layout: false)
  end

  action :edit do
    room_id, id = id_param("room_id"), id_param("id")
    require_authentication!
    room = room_scoped!(room_id)
    message = repo.room_message(room.id, id) or record_not_found!
    head_response(403) unless current_user.can_administer?(message)
    message_view = Messages.views(self, [ message ], cached: false).first
    body = repo.bodies([ message.id ])[message.id]
    view = build_view(view: message_view, message: message, room: room, editor_value: Messages.editor_value(self, body))
    render_layout(view, main: view.tpl_messages_edit, frame_layout: false)
  end

  action :update do
    room_id, id = id_param("room_id"), id_param("id")
    verify_same_origin!
    require_authentication!
    room = room_scoped!(room_id)
    message = repo.room_message(room.id, id) or record_not_found!
    head_response(403) unless current_user.can_administer?(message)
    message = Messages.update(self, room, message, (params["message"] || {})["body"])
    redirect url_for("/rooms/#{room.id}/messages/#{message.id}")
  end

  action :destroy do
    room_id, id = id_param("room_id"), id_param("id")
    verify_same_origin!
    require_authentication!
    room = room_scoped!(room_id)
    message = repo.room_message(room.id, id) or record_not_found!
    head_response(403) unless current_user.can_administer?(message)
    MessageRemoval.destroy(runtime, message)
    remove = %(<turbo-stream action="remove" target="message_#{message.client_message_id}"></turbo-stream>)
    Broadcasts.turbo_stream("#{RailsCompat.gid_param(room.type, room.id)}:messages", remove)
    html_headers("text/vnd.turbo-stream.html")
    remove
  end
end
