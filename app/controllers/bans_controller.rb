class BansController < ApplicationController
  action :create do
    id = id_param("id")
    verify_same_origin!
    require_authentication!
    head_response(403) unless current_user.can_administer?
    user = repo.user(id) or record_not_found!
    Bans.ban(self, user)
    redirect url_for("/users/#{user.id}")
  end

  action :destroy do
    id = id_param("id")
    verify_same_origin!
    require_authentication!
    head_response(403) unless current_user.can_administer?
    user = repo.user(id) or record_not_found!
    Bans.unban(self, user)
    redirect url_for("/users/#{user.id}")
  end
end
