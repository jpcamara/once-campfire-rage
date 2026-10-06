# Rails::HealthController: not an ApplicationController, so no version headers.
class HealthController < ApplicationController
  action :show do
    without_version_headers
    headers "cache-control" => "max-age=0, private, must-revalidate", "content-type" => "text/html; charset=utf-8"
    headers "vary" => "Accept" if vary_by_accept?
    %(<!DOCTYPE html><html><body style="background-color: green"></body></html>)
  end
end
