class TransfersController < ApplicationController
  action :show do
    view = build_view(request_path: request.path)
    render_layout(view, main: view.tpl_sessions_transfer)
  end

  action :update do
    verify_same_origin!
    user_id = secrets.find_signed_id(params["id"], "user/transfer")
    user = user_id && repo.user(user_id)
    head_response(400) unless user&.active?
    start_new_session_for(user)
    redirect_after_authentication
  end
end
