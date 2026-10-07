# Static pages from public/ (Rails' public file server).
class PublicFilesController < ApplicationController
  action :show do
    path = File.join(Campfire::ROOT, "public", request.path_info)
    env[Campfire::RequestId::STATIC] = true
    without_security_headers
    without_version_headers
    headers "cache-control" => "public, max-age=2592000", "last-modified" => File.mtime(path).httpdate,
      "content-type" => request.path_info.end_with?(".txt") ? "text/plain" : "text/html"
    Campfire.file_io { File.read(path) }
  end
end
