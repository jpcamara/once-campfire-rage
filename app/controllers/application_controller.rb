class ApplicationController < RageController::API
  include Campfire # the app's models, queries and views, by their short names
  include Campfire::Web
  include Campfire::Pages
end
