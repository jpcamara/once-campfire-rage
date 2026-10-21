module Campfire
  # Action Cable broadcasting through Rage::Cable. Iodine's pub/sub carries each broadcast to every
  # worker process, so no Redis is involved.
  module Broadcasts
    module_function

    def turbo_stream(stream, html)
      Rage.cable.broadcast(stream, html)
    end

    def json(stream, object)
      Rage.cable.broadcast(stream, object)
    end

    # ActionCable.server.remote_connections.where(current_user: user).disconnect(reconnect:): every
    # worker closes that user's connections.
    def disconnect_user(user_id, reconnect: false)
      ApplicationCable::Connection.disconnect(current_user_id: user_id, protocol_options: { reconnect: reconnect })
    end
  end
end
