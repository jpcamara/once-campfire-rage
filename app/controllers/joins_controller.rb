class JoinsController < ApplicationController
  action :new do
    return redirect(url_for("/")) if restore_authentication
    head_response(404) unless runtime.account.join_code == params["join_code"]
    view = build_view(join_code: params["join_code"])
    render_layout(view, page_title: "Sign up", body_class: "signup", nav: view.tpl_users_new_nav, main: view.tpl_users_new)
  end

  action :create do
    verify_same_origin!
    return redirect(url_for("/")) if restore_authentication
    head_response(404) unless runtime.account.join_code == params["join_code"]
    attributes = params["user"] || {}
    if (user = Users.create(self, attributes))
      start_new_session_for(user)
      redirect url_for("/")
    else
      redirect url_for("/session/new?#{URI.encode_www_form(email_address: attributes["email_address"])}")
    end
  end
end
