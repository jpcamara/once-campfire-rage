class ProfilesController < ApplicationController
  action :show do
    require_authentication!
    memberships = repo.sidebar_memberships(current_user.id, visible_only: false)
    directs, shared = memberships.partition { |_, room| room.direct? }
    view = build_view(user: current_user, direct_memberships: directs, shared_memberships: shared,
      avatar_attached: !repo.attachment_blob("User", current_user.id, "avatar").nil?)
    render_layout(view, page_title: current_user.name, nav: view.tpl_profiles_show_nav, main: view.tpl_profiles_show)
  end

  action :update do
    verify_same_origin!
    require_authentication!
    attributes = params["user"] || {}
    Profiles.update(self, current_user, attributes)
    redirect_with_notice("/users/me/profile", attributes["avatar"] ? "It may take up to 30 minutes to change everywhere." : "✓")
  end

  action :remove_avatar do
    verify_same_origin!
    require_authentication!
    Profiles.remove_avatar(self, current_user)
    redirect url_for("/users/me/profile")
  end
end
