class UnfurlsController < ApplicationController
  action :create do
    require_authentication!
    verify_same_origin!
    halt 400, "" if params["url"].to_s.empty?
    if (metadata = Unfurl.metadata(params["url"].to_s))
      headers "content-type" => "application/json; charset=utf-8"
      RailsJSON.generate(metadata)
    else
      status 204
      ""
    end
  end
end
