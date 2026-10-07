class SessionsController < ApplicationController
  action :new do
    # SessionsController#ensure_user_exists
    return redirect(url_for("/first_run")) unless db.value("SELECT 1 FROM users LIMIT 1")
    render_page(:sessions_new, page_title: "Sign in", head: %(<meta name="turbo-visit-control" content="reload">), email_address: params["email_address"])
  end

  action :create do
    verify_same_origin!
    return render_sign_in_rejection(429) if Campfire::RateLimit.exceeded?("sessions:#{remote_ip}", limit: 10, within: 180)
    user = repo.active_user_by_email(params["email_address"].to_s)
    if user && user.password_digest && BCrypt::Password.new(user.password_digest) == params["password"].to_s
      start_new_session_for(user)
      redirect_after_authentication
    else
      # authenticate_by hashes the password even when no user has that email (its `new(password:)`),
      # so a failed sign-in takes as long whether or not the address exists.
      BCrypt::Password.create(params["password"].to_s) unless user
      render_sign_in_rejection(401)
    end
  end

  action :destroy do
    require_authentication!
    verify_same_origin!
    db.transaction { |w| w.run("DELETE FROM sessions WHERE id = ?", @session.id) }
    Broadcasts.disconnect_user(current_user.id, reconnect: true) # Authentication#disconnect_remote_connections
    response.delete_cookie("session_token", path: "/")
    response.delete_cookie("_campfire_session", path: "/")
    redirect url_for("/")
  end
end
