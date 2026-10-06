class AutocompletesController < ApplicationController
  action :index do
    require_authentication!
    query = params["filter"].to_s.empty? ? params["query"].to_s : params["filter"].to_s
    users = Autocomplete.users(self, params["room_id"], query)
    if params["format"] == "json" || request.first_accepted_type == "application/json"
      headers "content-type" => "application/json; charset=utf-8"
      RailsJSON.generate(users.map { { name: HTML.h(it.name), value: it.id, avatar_url: url_for(build_view.avatar_path(it)), sgid: secrets.attachable_sgid("User", it.id) } })
    else
      view = build_view
      html_headers
      users.map { Autocomplete.prompt_item(view, it) }.join << "\n"
    end
  end
end
