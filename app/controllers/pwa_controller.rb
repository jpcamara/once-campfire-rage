class PwaController < ApplicationController
  action :manifest do
    account = runtime.account
    view = build_view
    headers "content-type" => "application/json; charset=utf-8", "cache-control" => "max-age=0, private, must-revalidate"
    Pwa.manifest(view, account, base_url)
  end

  action :service_worker do
    headers "content-type" => "text/javascript; charset=utf-8", "cache-control" => "max-age=0, private, must-revalidate"
    File.read(File.join(Campfire::ROOT, "public/service-worker.js"))
  end
end
