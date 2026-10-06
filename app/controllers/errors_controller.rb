# Unmatched paths: the static 404 page, as ActionDispatch::PublicExceptions serves it (no controller
# ran, so none of its headers).
class ErrorsController < ApplicationController
  action :not_found do
    record_not_found!
  end
end
