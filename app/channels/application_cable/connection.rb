module ApplicationCable
  # Authentication::SessionLookup: the session_token cookie names the user.
  class Connection < Rage::Cable::Connection
    identified_by :current_user

    def connect
      runtime = Campfire.runtime
      cookies = Rack::Utils.parse_cookies(@__env)
      token = cookies["session_token"] && runtime.secrets.verify_cookie("session_token", cookies["session_token"])
      session = token && runtime.repo.session_by_token(token)
      user = session && runtime.repo.user(session.user_id)
      user ? self.current_user = user : reject_unauthorized_connection
    end
  end
end
