# Rails::HealthController: not an ApplicationController, so no version headers.
class HealthController < ApplicationController
  action :show do
    without_version_headers
    headers "cache-control" => "max-age=0, private, must-revalidate", "content-type" => "text/html; charset=utf-8"
    %(<!DOCTYPE html><html><body style="background-color: green"></body></html>)
  end
end
