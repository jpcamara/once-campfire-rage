module ApplicationCable
  # Authentication::SessionLookup: the session_token cookie names the user.
  class Connection < Rage::Cable::Connection
    include Rage::Cable::RemoteDisconnect

    identified_by :current_user, :current_user_id

    def connect
      runtime = Campfire.runtime
      cookies = Rack::Utils.parse_cookies(@__env)
      token = cookies["session_token"] && runtime.secrets.verify_cookie("session_token", cookies["session_token"])
      session = token && runtime.repo.session_by_token(token)
      user = session && runtime.repo.user(session.user_id)
      if user
        self.current_user = user
        self.current_user_id = user.id
      else
        reject_unauthorized_connection
      end
    end
  end
end
