# The bot API: /rooms/:room_id/:bot_key/messages
class BotMessagesController < ApplicationController
  action :index do
    bot, room = bot_room_from_params!
    messages =
      if !params["before"].to_s.empty? then repo.page_before(room.id, (repo.room_message(room.id, params["before"].to_i) or record_not_found!).created_at)
      elsif !params["after"].to_s.empty? then repo.page_after(room.id, (repo.room_message(room.id, params["after"].to_i) or record_not_found!).created_at)
      else repo.last_page(room.id)
      end
    headers "x-total-count" => repo.room_message_count(room.id).to_s
    if (link = BotApi.next_page_link(self, room, params["bot_key"], messages))
      headers "link" => link
    end
    headers "content-type" => "application/json; charset=utf-8"
    RailsJSON.generate(messages.map { BotApi.message_json(self, it) })
  end

  action :create do
    bot, room = bot_room_from_params!
    @current_user = bot
    attachment = params["attachment"]
    request.body.rewind
    raw = request.body.read.to_s.force_encoding("UTF-8")
    head_response(422) if attachment.to_s.empty? && raw.empty?
    message_params = attachment.is_a?(Hash) ? { "attachment" => attachment } : { "body" => raw }
    message = Messages.create(self, room: room, creator: bot, params: message_params)
    Messages.after_create(self, room, message, message_views([ message ]).first)
    status 201
    headers "location" => url_for("/messages/#{message.id}")
    ""
  end

  action :update do
    id = message_id_param
    bot, room = bot_room_from_params!
    @current_user = bot
    message = repo.room_message(room.id, id) or record_not_found!
    head_response(403) unless bot.can_administer?(message)
    # Messages::ByBotsController#message_params: the raw request body is the message
    request.body.rewind
    message = Messages.update(self, room, message, request.body.read.to_s.force_encoding("UTF-8"))
    headers "content-type" => "application/json; charset=utf-8"
    RailsJSON.generate(BotApi.message_json(self, message))
  end

  action :destroy do
    id = message_id_param
    bot, room = bot_room_from_params!
    message = repo.room_message(room.id, id) or record_not_found!
    head_response(403) unless bot.can_administer?(message)
    MessageRemoval.destroy(runtime, message)
    Broadcasts.turbo_stream("#{RailsCompat.gid_param(room.type, room.id)}:messages", %(<turbo-stream action="remove" target="message_#{message.client_message_id}"></turbo-stream>))
    status 204
    ""
  end

  # Messages::Boosts::ByBotsController: the raw request body is the boost's content
  action :create_boost do
    bot, room = bot_room_from_params!
    @current_user = bot
    message = repo.room_message(room.id, id_param("message_id")) or head_response(404)
    request.body.rewind
    content = request.body.read.to_s.force_encoding("UTF-8")
    head_response(422) if content.strip.empty?
    boost = Boosts.create(self, message, content)
    status 201
    headers "content-type" => "application/json; charset=utf-8"
    RailsJSON.generate(BotApi.boost_json(self, boost, message))
  end

  action :destroy_boost do
    bot, room = bot_room_from_params!
    @current_user = bot
    message = repo.room_message(room.id, id_param("message_id")) or head_response(404)
    Boosts.destroy(self, message, message_id_param) or head_response(404)
    status 204
    ""
  end

  private
    def message_id_param
      params["id"].to_s.delete_suffix(".json").to_i
    end

    def bot_room_from_params!
      bot_room!(params["bot_key"].to_s, id_param("room_id"))
    end
end
