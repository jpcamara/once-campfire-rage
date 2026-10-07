class AccountLogosController < ApplicationController
  action :show do
    Avatars.account_logo(self)
  end

  action :destroy do
    require_authentication!
    verify_same_origin!
    head_response(403) unless current_user.can_administer?
    db.transaction do |w|
      w.run("DELETE FROM active_storage_attachments WHERE record_type = 'Account' AND name = 'logo'")
      w.run("UPDATE accounts SET updated_at = ?", TimeFormat.now_text)
    end
    redirect url_for("/account/edit")
  end
end
