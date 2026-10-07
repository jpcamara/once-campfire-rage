class PushSubscriptionsController < ApplicationController
  action :index do
    require_authentication!
    subscriptions = db.rows("SELECT id, endpoint, user_agent FROM push_subscriptions WHERE user_id = ?", current_user.id)
    view = build_view(subscriptions: subscriptions, last_room_visited: last_room_visited)
    render_layout(view, page_title: "Push notification subscriptions", nav: view.tpl_rooms_settings_nav, main: view.tpl_push_index)
  end

  action :create do
    require_authentication!
    verify_same_origin!
    attributes = params["push_subscription"] || {}
    halt 400, "" if attributes.empty?
    status PushSubscriptions.create(self, attributes) ? 200 : 422
    ""
  end

  action :destroy do
    id = id_param("id")
    require_authentication!
    verify_same_origin!
    db.transaction { |w| w.run("DELETE FROM push_subscriptions WHERE id = ? AND user_id = ?", id, current_user.id) }
    redirect url_for("/users/me/push_subscriptions")
  end

  action :test do
    id = id_param("id")
    require_authentication!
    verify_same_origin!
    row = db.row("SELECT endpoint, p256dh_key, auth_key FROM push_subscriptions WHERE id = ? AND user_id = ?", id, current_user.id) or record_not_found!
    payload = { title: "Campfire Test", body: SecureRandom.uuid, path: url_for("/users/me/push_subscriptions") }
    badge = db.value("SELECT COUNT(*) FROM memberships WHERE user_id = ? AND unread_at IS NOT NULL", current_user.id)
    Push.deliver(runtime, id, *row, payload, badge) if Push.permitted?(row[0])
    redirect url_for("/users/me/push_subscriptions")
  end
end
