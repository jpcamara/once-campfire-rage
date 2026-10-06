require "json"

module Campfire
  # The Action Cable protocol (actioncable-v1-json) on Rage::Cable, framed as the Rails app frames it:
  # broadcasts carry the subscription's identifier exactly as the client sent it and the payload as
  # Action Cable encoded it, pings carry the time, `unsubscribe` ends one subscription, and unknown
  # channels, commands and actions are ignored rather than answered.
  #
  # A broadcast reaches the subscriptions that exist when it arrives, as with Action Cable's Redis
  # adapter: it goes to every worker once, and each worker hands it to the subscriptions it holds
  # then, through Iodine's per-subscription channels (which write to the sockets without Ruby).
  class CableProtocol < Rage::Cable::Protocols::Base
    IDENTIFIER = :__identifier # the raw identifier, kept in each subscription's params
    BROADCASTS = "campfire:broadcasts"
    DISCONNECTS = "campfire:disconnects"
    PING_INTERVAL_MS = 3_000
    HANDSHAKE_HEADERS = { "Sec-WebSocket-Protocol" => "actioncable-v1-json" } # not frozen: Iodine writes to it
    WELCOME = %({"type":"welcome"})
    UNAUTHORIZED = %({"type":"disconnect","reason":"unauthorized","reconnect":false})

    class << self
      def protocol_definition = HANDSHAKE_HEADERS

      def init(router)
        super
        @streams = Hash.new { |streams, name| streams[name] = {} } # this worker's subscriptions: stream => { id => params }
        @connections = Hash.new { |connections, user_id| connections[user_id] = [] } # this worker's connections by user
        Iodine.on_state(:on_start) do
          Iodine.subscribe(BROADCASTS) { |_channel, message| deliver(message) }
          Iodine.subscribe(DISCONNECTS) { |_channel, message| disconnect(*message.split(",")) }
          Iodine.run_every(PING_INTERVAL_MS) do
            Iodine.publish("cable:ping", %({"type":"ping","message":#{Time.now.to_i}}), Iodine::PubSub::PROCESS)
          end
        end
      end

      def on_open(connection)
        if @router.process_connection(connection)
          @connections[user_id(connection)] << connection
          connection.subscribe("cable:ping")
          connection.write(WELCOME)
        else
          connection.write(UNAUTHORIZED)
          connection.close
        end
      end

      def on_message(connection, raw)
        command = JSON.parse(raw)
        identifier = command["identifier"].to_s
        case command["command"]
        when "subscribe" then subscribe_to(connection, identifier)
        when "unsubscribe" then unsubscribe_from(connection, identifier)
        when "message" then perform(connection, identifier, command["data"])
        end
      rescue JSON::ParserError
        nil
      end

      def on_close(connection)
        if (id = user_id(connection))
          @connections[id].delete(connection)
          @connections.delete(id) if @connections[id].empty?
        end
        @router.process_disconnection(connection)
      end

      def disconnect_user(user_id, reconnect:)
        Iodine.publish(DISCONNECTS, "#{user_id},#{reconnect}")
      end

      def subscribe(connection, name, params)
        id = stream_id(params)
        connection.subscribe("cable:#{name}:#{id}")
        @streams[name][id] ||= params
      end

      def broadcast(name, payload)
        Iodine.publish(BROADCASTS, "#{name}\0#{payload}")
      end

      def serialize(params, payload)
        %({"identifier":#{JSON.generate(params[IDENTIFIER])},"message":#{payload}})
      end

      private
        def user_id(connection) = connection.env["rage.identified_by"]&.[](:current_user)&.id

        # ActionCable::Connection::Base#close(reason: "remote", reconnect:)
        def disconnect(user_id, reconnect)
          @connections.fetch(user_id.to_i, nil)&.dup&.each do |connection|
            connection.write(%({"type":"disconnect","reason":"remote","reconnect":#{reconnect}}))
            connection.close
          end
        end

        def deliver(message)
          name, payload = message.split("\0", 2)
          @streams.fetch(name, nil)&.each do |id, params|
            Iodine.publish("cable:#{name}:#{id}", serialize(params, payload), Iodine::PubSub::PROCESS)
          end
        end

        def subscribe_to(connection, identifier)
          return if connection.env["rage.cable"].key?(identifier)
          params = JSON.parse(identifier, symbolize_names: true).merge(IDENTIFIER => identifier)
          case @router.process_subscription(connection, identifier, params[:channel].to_s, params)
          when :subscribed then connection.write(%({"identifier":#{JSON.generate(identifier)},"type":"confirm_subscription"}))
          when :rejected then connection.write(%({"identifier":#{JSON.generate(identifier)},"type":"reject_subscription"}))
          end
        end

        def unsubscribe_from(connection, identifier)
          channel = connection.env["rage.cable"].delete(identifier) or return
          channel.__run_action(:unsubscribed)
          channel.send(:stop_all_streams)
        end

        def perform(connection, identifier, data)
          data = JSON.parse(data.to_s)
          action = data["action"] ? data["action"].to_sym : :receive
          @router.process_message(connection, identifier, action, data)
        end
    end
  end
end
