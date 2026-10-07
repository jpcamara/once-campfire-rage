class AccountsController < ApplicationController
  action :edit do
    require_authentication!
    statuses = current_user.can_administer? ? "0, 2" : "0"
    users = db.rows("SELECT #{User.columns} FROM users WHERE status IN (#{statuses}) AND role != 2 ORDER BY LOWER(name)").map { User.new(*it) }
    administrators, members = users.partition(&:administrator?)
    view = build_view(administrators: administrators, members: members, next_page: users.size > 500 ? 2 : nil,
      last_room_visited: last_room_visited)
    footer = %(<div class="txt-align-center center margin-block-double txt-subtle">Campfire&trade; version <span class="version-badge">#{HTML.h(runtime.app_version)}</span></div>)
    render_layout(view, page_title: "Account settings", nav: view.tpl_accounts_edit_nav, main: view.tpl_accounts_edit, footer: footer)
  end

  action :update do
    require_authentication!
    verify_same_origin!
    head_response(403) unless current_user.can_administer?
    Accounts.update(self, params["account"] || {})
    redirect_with_notice("/account/edit", "✓")
  end

  action :reset_join_code do
    require_authentication!
    verify_same_origin!
    head_response(403) unless current_user.can_administer?
    code = SecureRandom.alphanumeric(12).scan(/.{4}/).join("-")
    db.transaction { |w| w.run("UPDATE accounts SET join_code = ?, updated_at = ?", code, TimeFormat.now_text) }
    redirect url_for("/account/edit")
  end
end
