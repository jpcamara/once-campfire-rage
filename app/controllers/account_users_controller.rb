class AccountUsersController < ApplicationController
  action :index do
    require_authentication!
    page = [ params["page"].to_i, 1 ].max
    users = db.rows("SELECT #{User.columns} FROM users WHERE status = 0 AND role != 2 ORDER BY LOWER(name) LIMIT 500 OFFSET ?", (page - 1) * 500).map { User.new(*it) }
    more = db.value("SELECT COUNT(*) FROM users WHERE status = 0 AND role != 2") > page * 500
    view = build_view
    html = %(<turbo-stream action="replace" target="next_page_container"><template>#{users.map { view.render_account_user(it) }.join}</template></turbo-stream>)
    html << %(<turbo-stream action="append" target="account_users"><template><turbo-frame loading="lazy" src="/account/users.turbo_stream?page=#{page + 1}" class="flex center" id="next_page_container">\n  <div class="spinner center"></div>\n</turbo-frame></template></turbo-stream>) if more
    html_headers("text/vnd.turbo-stream.html")
    html
  end

  action :update do
    id = id_param("id")
    verify_same_origin!
    require_authentication!
    head_response(403) unless current_user.can_administer?
    user = repo.user(id)
    record_not_found! unless user&.active?
    role = %w[ member administrator ].include?((params["user"] || {})["role"]) ? params["user"]["role"] : "member"
    db.transaction { |w| w.run("UPDATE users SET role = ?, updated_at = ? WHERE id = ?", role == "administrator" ? 1 : 0, TimeFormat.now_text, user.id) }
    redirect url_for("/account/edit")
  end

  action :destroy do
    id = id_param("id")
    verify_same_origin!
    require_authentication!
    head_response(403) unless current_user.can_administer?
    user = repo.user(id)
    record_not_found! unless user&.active?
    Accounts.deactivate(self, user)
    redirect url_for("/account/edit")
  end
end
