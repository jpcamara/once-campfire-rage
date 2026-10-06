class SidebarsController < ApplicationController
  action :show do
    require_authentication!
    html_headers
    render_sidebar
  end
end
