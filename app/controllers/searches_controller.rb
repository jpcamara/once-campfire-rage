class SearchesController < ApplicationController
  action :index do
    require_authentication!
    raw = params["q"]
    query = raw&.gsub(/[^[:word:]]/, " ")
    messages = query.to_s.strip.empty? ? [] : repo.search(current_user.id, query)
    render_search(query.to_s.strip.empty? ? nil : query, raw, messages)
  end

  action :create do
    verify_same_origin!
    require_authentication!
    query = params["q"]&.gsub(/[^[:word:]]/, " ")
    Searches.record(self, current_user, query)
    redirect url_for("/searches?q=#{URI.encode_www_form_component(query.to_s)}")
  end

  action :clear do
    verify_same_origin!
    require_authentication!
    db.transaction { |w| w.run("DELETE FROM searches WHERE user_id = ?", current_user.id) }
    redirect url_for("/searches")
  end
end
