# Subscribes to a room's channels on two servers as the same user, posts one message to each, and
# prints every frame (pings dropped) so the two can be diffed.
#   bundle exec ruby script/cable_frames.rb BASE COOKIE_JAR ROOM_ID [CSRF]
require "async"
require "async/http/endpoint"
require "async/websocket/client"
require "json"
require "net/http"

base, jar, room_id = ARGV
cookie = File.readlines(jar).grep(/\t(session_token|_campfire_session)\t/).map { it.split("\t").values_at(5, 6).map(&:strip).join("=") }.join("; ")
http = Net::HTTP.new(URI(base).host, URI(base).port)
page = http.get("/rooms/#{room_id}", "Cookie" => cookie).body
sidebar = http.get("/users/me/sidebar", "Cookie" => cookie).body
csrf = page[/name="csrf-token" content="([^"]*)"/, 1]
streams = (page + sidebar).scan(/<turbo-cable-stream-source channel="([^"]+)" signed-stream-name="([^"]+)"/).uniq
identifiers = streams.map { |channel, name| JSON.generate(channel: channel, signed_stream_name: name.gsub("&quot;", '"')) } +
  [ JSON.generate(channel: "PresenceChannel", room_id: room_id.to_i), JSON.generate(channel: "UnreadRoomsChannel"),
    JSON.generate(channel: "ReadRoomsChannel"), JSON.generate(channel: "TypingNotificationsChannel", room_id: room_id.to_i) ]

frames = []
Async do |task|
  endpoint = Async::HTTP::Endpoint.parse("#{base.sub("http", "ws")}/cable")
  Async::WebSocket::Client.connect(endpoint, headers: { "cookie" => cookie, "origin" => base }, protocols: [ "actioncable-v1-json" ]) do |ws|
    identifiers.each { ws.write(Protocol::WebSocket::TextMessage.generate({ command: "subscribe", identifier: it })); ws.flush }
    reader = task.async do
      while (message = ws.read)
        data = JSON.parse(message.to_str)
        frames << data unless data["type"] == "ping"
      end
    end
    task.sleep 1
    request = Net::HTTP::Post.new("/rooms/#{room_id}/messages", "Cookie" => cookie, "Sec-Fetch-Site" => "same-origin",
      "X-CSRF-Token" => csrf.to_s, "Accept" => "text/vnd.turbo-stream.html, text/html")
    request.set_form_data("message[body]" => "<p>cable frame check</p>", "message[client_message_id]" => "cable-check")
    Async::HTTP::Internet.new rescue nil
    Thread.new { http.request(request) }.join
    ws.write(Protocol::WebSocket::TextMessage.generate({ command: "message", identifier: identifiers.last, data: JSON.generate(action: "start") }))
    ws.flush
    task.sleep(ENV.fetch("WAIT", 1.5).to_f)
    reader.stop
  end
end
frames.each { puts JSON.generate(it) }
