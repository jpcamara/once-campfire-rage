class FirstRunsController < ApplicationController
  action :show do
    return redirect(url_for("/")) if runtime.account
    render_page(:first_runs_show, page_title: "Set up Campfire", body_class: "signup")
  end

  action :create do
    verify_same_origin!
    return redirect(url_for("/")) if runtime.account
    user = Users.first_run(self, params["user"] || {})
    start_new_session_for(user)
    redirect url_for("/")
  end
end
