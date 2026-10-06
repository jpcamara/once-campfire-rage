class UsersController < ApplicationController
  action :show do
    id = id_param("id")
    require_authentication!
    user = repo.user(id) or record_not_found!
    view = build_view(user: user)
    render_layout(view, page_title: user.name, nav: view.tpl_users_show_nav, main: view.tpl_users_show)
  end
end
