module Turbo
  class StreamsChannel < ApplicationCable::Channel
    def subscribed
      name = runtime.secrets.verified_stream_name(params[:signed_stream_name].to_s)
      # config/initializers/turbo_streams_authorization.rb: room message streams only through RoomMessagesChannel
      return reject if name.nil? || name.split(":", 2)[1] == "messages"
      stream_from(name)
    end
  end
end
