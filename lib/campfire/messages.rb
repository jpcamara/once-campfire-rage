require "securerandom"

module Campfire
  module Messages
    module_function

    # Repo::MessageView for each message. Messages whose fragment is already cached get a bare view
    # (only the cache key is read); the rest load their bodies, attachments, creators and boosts.
    def views(ctx, messages, cached: true)
      return [] if messages.empty?

      cache = ctx.runtime.fragment_cache
      host = ctx.base_url
      misses = cached ? messages.reject { cache.key?([ it.id, it.updated_at, host ]) } : messages
      return messages.map { bare(it) } if misses.empty?

      repo = ctx.repo
      ids = misses.map(&:id)
      bodies = repo.bodies(ids)
      attachments = repo.message_attachments(ids)
      boosts = repo.boosts(ids)
      users = repo.users((misses.map(&:creator_id) + boosts.values.flatten.map(&:booster_id)).uniq)
      rooms = repo.rooms(misses.map(&:room_id).uniq)
      missed = ids.to_h { [ it, true ] }

      messages.map do |message|
        next bare(message) unless missed[message.id]

        body = bodies[message.id]
        attachment = attachments[message.id]
        plain = plain_text_body(ctx, body, attachment)
        Repo::MessageView.new(
          message: message,
          creator: users[message.creator_id],
          room: rooms[message.room_id],
          presentation: presentation(ctx, body, attachment, plain),
          attachment: attachment,
          boosts: (boosts[message.id] || []).map { [ it, users[it.booster_id] ] },
          emoji: ctx.runtime.all_emoji?(plain))
      end
    end

    def bare(message)
      Repo::MessageView.new(message: message, creator: nil, room: nil, presentation: nil, attachment: nil, boosts: nil, emoji: nil)
    end

    # Message#plain_text_body
    def plain_text_body(ctx, body, attachment)
      text = body ? PlainText.convert(body, attachment_text: ->(node) { Attachments.plain_text(ctx, node) }) : ""
      text = attachment.filename if text.strip.empty? && attachment
      text.strip.empty? && !attachment ? "" : text
    end

    def presentation(ctx, body, attachment, plain)
      if attachment
        Attachments.presentation(ctx, attachment)
      elsif (sound = sound_for(plain))
        Sounds.presentation(sound)
      else
        RichText.presentation(body.to_s, attachment_renderer: ->(node) { Attachments.render(ctx, node) },
          attachment_text: ->(node) { Attachments.plain_text(ctx, node) })
      end
    rescue => error
      warn "presentation failed: #{error.class}: #{error.message}"
      ""
    end

    def sound_for(plain)
      (match = plain.match(/\A\/play (?<name>\w+)\z/)) && Sound.find_by_name(match[:name])
    end

    Created = Data.define(:message, :body, :plain, :blob)

    def create(...) = create_with_details(...).message

    # A new message and its view. A text message's view is built from what the request already holds;
    # an attachment's blob gains metadata as it's processed, so that view is loaded. With
    # CAMPFIRE_CHECK_CACHES=1 the built view is rendered against a loaded one and a mismatch logged.
    def post(ctx, room:, creator:, params:)
      created = create_with_details(ctx, room: room, creator: creator, params: params)
      message = created.message
      return [ created, views(ctx, [ message ]).first ] if created.blob

      plain = created.plain.strip.empty? ? "" : created.plain
      view = Repo::MessageView.new(message: message, creator: creator, room: room,
        presentation: presentation(ctx, created.body, nil, plain), attachment: nil, boosts: [], emoji: ctx.runtime.all_emoji?(plain))
      check_view(ctx, view) if ENV["CAMPFIRE_CHECK_CACHES"]
      [ created, view ]
    end

    def check_view(ctx, view)
      loaded = views(ctx, [ view.message ], cached: false).first
      built, fresh = ctx.build_view.render_message(view), ctx.build_view.render_message(loaded)
      warn "CACHE MISMATCH new message view #{view.message.id}" unless built == fresh
    end

    # MessagesController#create's Message.create!: the message, its rich text body, the room touch,
    # the search index row and the unread flags, in one transaction.
    def create_with_details(ctx, room:, creator:, params:)
      client_message_id = params["client_message_id"].to_s
      client_message_id = SecureRandom.uuid if client_message_id.empty?
      body = canonical_body(params["body"])
      upload = params["attachment"]
      blob = upload.is_a?(Hash) && upload[:tempfile] ? Uploads.store(ctx, upload) : nil
      plain = blob && body.to_s.strip.empty? ? blob.filename : PlainText.convert(body.to_s, attachment_text: ->(node) { Attachments.plain_text(ctx, node) })
      plain = blob.filename if plain.strip.empty? && blob

      created_at = TimeFormat.now_text
      message = ctx.db.transaction do |w|
        w.run("INSERT INTO messages (client_message_id, created_at, creator_id, room_id, updated_at) VALUES (?, ?, ?, ?, ?)",
          client_message_id, created_at, creator.id, room.id, created_at)
        id = w.last_insert_row_id
        updated_at = TimeFormat.now_text
        unless body.nil?
          w.run("INSERT INTO action_text_rich_texts (body, created_at, name, record_id, record_type, updated_at) VALUES (?, ?, 'body', ?, 'Message', ?)",
            body, updated_at, id, updated_at)
        end
        Uploads.attach(w, blob, "Message", id, "attachment", updated_at) if blob
        w.run("UPDATE messages SET updated_at = ? WHERE id = ?", updated_at, id)
        w.run("UPDATE rooms SET updated_at = ? WHERE id = ?", updated_at, room.id)
        w.run("INSERT INTO message_search_index(rowid, body) VALUES (?, ?)", id, plain)
        w.run(<<~SQL, created_at, updated_at, room.id, (Time.now.utc - 60).strftime("%Y-%m-%d %H:%M:%S.%6N"), creator.id)
          UPDATE memberships SET unread_at = ?, updated_at = ?
          WHERE memberships.room_id = ? AND memberships.involvement != 'invisible'
          AND (memberships.connected_at IS NULL OR memberships.connected_at < ?) AND memberships.user_id != ?
        SQL
        Message.new(id, client_message_id, created_at, creator.id, room.id, updated_at)
      end
      Uploads.process(ctx, blob) if blob
      Created.new(message, body, plain, blob)
    end

    # What ActionText::RichText stores: the canonicalized fragment's HTML.
    def canonical_body(value)
      return nil if value.nil?
      html = value.to_s
      return html if html.strip.empty?
      RichText.to_html(Attachments.canonicalize(RichText.fragment(html)))
    end

    # RichTextHelper#editable_body, then Lexxy's render_custom_attachments_in: each attachment
    # carries its content type and its rendered partial (as JSON) for the editor.
    def editor_value(ctx, body)
      return "" if body.nil?
      frag = RichText.fragment(body)
      frag.css(RichText::ATTACHMENT_TAG).each do |node|
        node["content-type"] = Attachments.content_type(ctx, node)
        node["content"] = Attachments.render(ctx, node, editor: true)
      end
      frag = RichText.fragment(RichText.to_html(frag))
      frag.css(RichText::ATTACHMENT_TAG).each do |node|
        next unless node["url"].to_s.strip.empty?
        node["content"] = JSON.generate(Attachments.render(ctx, node, editor: true)).gsub("<", "\\u003c").gsub(">", "\\u003e").gsub("&", "\\u0026")
        node["content-type"] ||= Attachments.content_type(ctx, node)
      end
      RichText.to_html(frag)
    end

    # MessagesController#update: the new body, the search index, and the presentation broadcast.
    def update(ctx, room, message, body)
      body = canonical_body(body)
      now = TimeFormat.now_text
      plain = PlainText.convert(body.to_s, attachment_text: ->(node) { Attachments.plain_text(ctx, node) })
      ctx.db.transaction do |w|
        if w.value("SELECT 1 FROM action_text_rich_texts WHERE record_type = 'Message' AND record_id = ? AND name = 'body'", message.id)
          w.run("UPDATE action_text_rich_texts SET body = ?, updated_at = ? WHERE record_type = 'Message' AND record_id = ? AND name = 'body'", body, now, message.id)
        else
          w.run("INSERT INTO action_text_rich_texts (body, created_at, name, record_id, record_type, updated_at) VALUES (?, ?, 'body', ?, 'Message', ?)", body, now, message.id, now)
        end
        w.run("UPDATE messages SET updated_at = ? WHERE id = ?", now, message.id)
        w.run("UPDATE rooms SET updated_at = ? WHERE id = ?", now, room.id)
        w.run("UPDATE message_search_index SET body = ? WHERE rowid = ?", plain, message.id)
      end
      message = ctx.repo.room_message(room.id, message.id)
      view = views(ctx, [ message ], cached: false).first
      html = %(<div id="presentation_message_#{message.client_message_id}" dir="auto" data-reply-target="body" data-messages-target="body">\n  #{view.presentation}\n</div>\n)
      Broadcasts.turbo_stream("#{RailsCompat.gid_param(room.type, room.id)}:messages",
        %(<turbo-stream maintain_scroll="true" action="replace" target="presentation_message_#{message.client_message_id}"><template>#{html}</template></turbo-stream>))
      message
    end

    # After commit: the room broadcast, unread notifications, push notifications and bot webhooks.
    # `created`, when given, hands the push job the body and plain text it would otherwise reload.
    def after_create(ctx, room, message, view, webhooks: true, created: nil)
      html = ctx.build_view.render_message_cached(view)
      stream = "#{RailsCompat.gid_param(room.type, room.id)}:messages"
      Broadcasts.turbo_stream(stream, %(<turbo-stream action="append" target="messages_#{room.param_key}_#{room.id}"><template>#{html}</template></turbo-stream>))

      member_ids = ctx.db.rows("SELECT memberships.user_id FROM memberships WHERE memberships.room_id = ?", room.id).map(&:first)
      payload = %({"roomId":#{room.id}})
      member_ids.each { Broadcasts.raw("user_#{it}_unreads", payload) }

      if created && !created.blob
        plain = created.plain.strip.empty? ? "" : created.plain
        Jobs.later(Push, :deliver_for_message, nil, room.id, message.id, created.body, plain, view.creator.id)
      else
        Jobs.later(Push, :deliver_for_message, nil, room.id, message.id)
      end
      Webhooks.deliver_later(ctx.runtime, room, message) if webhooks
    end
  end
end
