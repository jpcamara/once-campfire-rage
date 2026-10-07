class InvolvementsController < ApplicationController
  action :show do
    room_id = id_param("room_id")
    require_authentication!
    membership = repo.membership(current_user.id, room_id) or record_not_found!
    room = repo.room(membership.room_id)
    view = build_view
    frame = %(<turbo-frame data-controller="turbo-frame" data-action="notifications:ready@window-&gt;turbo-frame#load" data-turbo-frame-url-param="/rooms/#{room.id}/involvement" id="involvement_#{room.param_key}_#{room.id}">\n  #{view.involvement_button(room, membership.involvement)}\n</turbo-frame>)
    render_layout(view, main: frame)
  end

  action :update do
    room_id = id_param("room_id")
    require_authentication!
    verify_same_origin!
    membership = repo.membership(current_user.id, room_id) or record_not_found!
    Involvements.update(self, membership, params["involvement"].to_s)
    redirect url_for("/rooms/#{membership.room_id}/involvement")
  end
end
