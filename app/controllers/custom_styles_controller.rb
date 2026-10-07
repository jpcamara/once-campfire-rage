class CustomStylesController < ApplicationController
  action :edit do
    require_authentication!
    head_response(403) unless current_user.can_administer?
    view = build_view
    render_layout(view, page_title: "Custom styles", nav: view.tpl_accounts_custom_styles_nav, main: view.tpl_accounts_custom_styles)
  end

  action :update do
    require_authentication!
    verify_same_origin!
    head_response(403) unless current_user.can_administer?
    db.transaction { |w| w.run("UPDATE accounts SET custom_styles = ?, updated_at = ?", (params["account"] || {})["custom_styles"], TimeFormat.now_text) }
    redirect_with_notice("/account/custom_styles/edit", "✓")
  end
end
