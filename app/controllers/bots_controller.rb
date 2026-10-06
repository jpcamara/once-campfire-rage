class BotsController < ApplicationController
  action :index do
    require_authentication!
    head_response(403) unless current_user.can_administer?
    bots = db.rows("SELECT #{User.columns} FROM users WHERE status = 0 AND role = 2 ORDER BY LOWER(name)").map { User.new(*it) }
    bots = bots.map do |bot|
      rooms = db.rows(<<~SQL, bot.id).map { Room.new(*it) }
        SELECT #{Room.columns} FROM rooms INNER JOIN memberships ON rooms.id = memberships.room_id
        WHERE memberships.user_id = ? AND rooms.type != 'Rooms::Direct' ORDER BY LOWER(name)
      SQL
      [ bot, rooms ]
    end
    view = build_view(bots: bots, back_path: "/account/edit")
    render_layout(view, page_title: "Chat bots", nav: view.tpl_bots_back_nav, main: view.tpl_bots_index)
  end

  action :new do
    require_authentication!
    head_response(403) unless current_user.can_administer?
    view = build_view(bot: nil, bot_avatar_src: Assets.path("default-bot-avatar.svg"), webhook_url: nil, back_path: "/account/bots")
    render_layout(view, page_title: "New chat bot", nav: view.tpl_bots_back_nav, main: view.tpl_bots_form)
  end

  action :edit do
    id = id_param("id")
    require_authentication!
    head_response(403) unless current_user.can_administer?
    bot = active_bot!(id)
    avatar = repo.attachment_blob("User", bot.id, "avatar")
    view = build_view(bot: bot, bot_avatar_src: avatar ? url_for(Storage.blob_path(runtime, avatar)) : Assets.path("default-bot-avatar.svg"),
      webhook_url: db.value("SELECT url FROM webhooks WHERE user_id = ? LIMIT 1", bot.id), back_path: "/account/bots")
    render_layout(view, page_title: "Edit bot", nav: view.tpl_bots_back_nav, main: view.tpl_bots_form)
  end

  action :create do
    verify_same_origin!
    require_authentication!
    head_response(403) unless current_user.can_administer?
    BotAccounts.create(self, params["user"] || {})
    redirect url_for("/account/bots")
  end

  action :update do
    id = id_param("id")
    verify_same_origin!
    require_authentication!
    head_response(403) unless current_user.can_administer?
    BotAccounts.update(self, active_bot!(id), params["user"] || {})
    redirect url_for("/account/bots")
  end

  action :reset_key do
    id = id_param("id")
    verify_same_origin!
    require_authentication!
    head_response(403) unless current_user.can_administer?
    bot = active_bot!(id)
    db.transaction { |w| w.run("UPDATE users SET bot_token = ?, updated_at = ? WHERE id = ?", SecureRandom.alphanumeric(12), TimeFormat.now_text, bot.id) }
    redirect url_for("/account/bots")
  end

  action :destroy do
    id = id_param("id")
    verify_same_origin!
    require_authentication!
    head_response(403) unless current_user.can_administer?
    Accounts.deactivate(self, active_bot!(id))
    redirect url_for("/account/bots")
  end
end
