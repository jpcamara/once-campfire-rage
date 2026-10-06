class AvatarsController < ApplicationController
  action :show do
    require_authentication!
    Avatars.show(self, params["token"])
  end
end
