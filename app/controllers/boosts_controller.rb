class BoostsController < ApplicationController
  action :index do
    message_id = id_param("message_id")
    require_authentication!
    message = reachable_message!(message_id)
    view = build_view
    message_view = Messages.views(self, [ message ], cached: false).first
    render_layout(view, main: view.with(message: message, view: message_view).render_boosts(message_view))
  end

  action :new do
    message_id = id_param("message_id")
    require_authentication!
    message = reachable_message!(message_id)
    view = build_view(message: message)
    render_layout(view, main: view.tpl_boosts_new)
  end

  action :create do
    message_id = id_param("message_id")
    require_authentication!
    verify_same_origin!
    message = reachable_message!(message_id)
    Boosts.create(self, message, (params["boost"] || {})["content"].to_s)
    redirect url_for("/messages/#{message.id}/boosts")
  end

  action :destroy do
    message_id, id = id_param("message_id"), id_param("id")
    require_authentication!
    verify_same_origin!
    message = reachable_message!(message_id)
    Boosts.destroy(self, message, id) or record_not_found!
    status 204
    ""
  end
end
