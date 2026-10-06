require "json"

module Campfire
  # Action Cable broadcasting through Rage::Cable. Iodine's pub/sub carries each broadcast to every
  # worker process, so no Redis is involved. A payload is the message's JSON, as Action Cable
  # encodes it.
  module Broadcasts
    module_function

    # A Turbo Stream broadcast: Action Cable JSON-encodes the HTML string.
    def turbo_stream(stream, html)
      raw(stream, JSON.generate(html))
    end

    def json(stream, object)
      raw(stream, JSON.generate(object))
    end

    def raw(stream, payload)
      Rage.cable.broadcast(stream, payload)
    end
  end
end
