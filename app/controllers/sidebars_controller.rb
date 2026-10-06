class SidebarsController < ApplicationController
  action :show do
    record_not_found! unless params["id"] == "me" || params["id"].to_s.match?(/\A\d+\z/)
    require_authentication!
    html_headers
    render_sidebar
  end
end
