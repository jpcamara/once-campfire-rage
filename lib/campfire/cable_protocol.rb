require "json"

module Campfire
  # The Action Cable protocol (actioncable-v1-json) on Rage::Cable, framed as the Rails app frames it:
  # broadcasts carry the subscription's identifier exactly as the client sent it and the payload as
  # Action Cable encoded it, pings carry the time, `unsubscribe` ends one subscription, and unknown
  # channels, commands and actions are ignored rather than answered.
  class CableProtocol < Rage::Cable::Protocols::Base
    IDENTIFIER = :__identifier # the raw identifier, kept in each subscription's params
    PING_INTERVAL_MS = 3_000
    HANDSHAKE_HEADERS = { "Sec-WebSocket-Protocol" => "actioncable-v1-json" }.freeze
    WELCOME = %({"type":"welcome"})
    UNAUTHORIZED = %({"type":"disconnect","reason":"unauthorized","reconnect":false})

    class << self
      def protocol_definition = HANDSHAKE_HEADERS

      def init(router)
        super
        Iodine.on_state(:on_start) do
          Iodine.run_every(PING_INTERVAL_MS) do
            Iodine.publish("cable:ping", %({"type":"ping","message":#{Time.now.to_i}}), Iodine::PubSub::PROCESS)
          end
        end
      end

      def on_open(connection, env)
        if @router.process_connection(env)
          connection.subscribe("cable:ping")
          connection.write(WELCOME)
        else
          connection.write(UNAUTHORIZED)
          connection.close
        end
      end

      def on_message(connection, env, raw)
        command = JSON.parse(raw)
        identifier = command["identifier"].to_s
        case command["command"]
        when "subscribe" then subscribe_to(connection, env, identifier)
        when "unsubscribe" then unsubscribe_from(env, identifier)
        when "message" then perform(env, identifier, command["data"])
        end
      rescue JSON::ParserError
        nil
      end

      def on_close(_connection, env)
        @router.process_disconnection(env)
      end

      def serialize(params, payload)
        %({"identifier":#{JSON.generate(params[IDENTIFIER])},"message":#{payload}})
      end

      private
        def subscribe_to(connection, env, identifier)
          return if env["rage.cable"].key?(identifier)
          params = JSON.parse(identifier, symbolize_names: true).merge(IDENTIFIER => identifier)
          case @router.process_subscription(connection, env, identifier, params[:channel].to_s, params)
          when :subscribed then connection.write(%({"identifier":#{JSON.generate(identifier)},"type":"confirm_subscription"}))
          when :rejected then connection.write(%({"identifier":#{JSON.generate(identifier)},"type":"reject_subscription"}))
          end
        end

        def unsubscribe_from(env, identifier)
          channel = env["rage.cable"].delete(identifier) or return
          channel.__run_action(:unsubscribed)
          channel.send(:stop_all_streams)
        end

        def perform(env, identifier, data)
          data = JSON.parse(data.to_s)
          action = data["action"] ? data["action"].to_sym : :receive
          @router.process_message(env, identifier, action, data)
        end
    end
  end
end
