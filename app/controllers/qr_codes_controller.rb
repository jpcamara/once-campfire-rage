class QrCodesController < ApplicationController
  action :show do
    QrCodes.show(self, params["id"])
  end
end
