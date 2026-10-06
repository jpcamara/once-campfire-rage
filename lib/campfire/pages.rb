module Campfire
  # Helpers shared by the room, message, sidebar and search actions.
  module Pages
    # Authentication's restore_authentication || bot_authentication, then the user's room
    def bot_room!(bot_key, room_id)
      bot = restore_authentication
      unless bot
        id, token = bot_key.strip.split("-", 2)
        row = db.row("SELECT #{User.columns} FROM users WHERE id = ? AND bot_token = ? AND status = 0 AND role = 2 LIMIT 1", id.to_i, token.to_s)
        halt 302, { "Location" => url_for("/session/new") }, "" unless row
        bot = User.new(*row)
      end
      room = repo.user_room(bot.id, room_id.to_i) or head_response(404)
      [ bot, room ]
    end

    def active_bot!(id)
      row = db.row("SELECT #{User.columns} FROM users WHERE id = ? AND status = 0 AND role = 2", id.to_i) or record_not_found!
      User.new(*row)
    end

    def can_create_rooms?
      current_user.administrator? || !runtime.account.restrict_room_creation_to_administrators?
    end

    def render_room_settings(form_type, room)
      users = repo.active_users_ordered
      editing = !room.nil?
      administer = editing ? current_user.can_administer?(room) : true
      if form_type == "closed"
        member_ids = editing ? repo.room_user_ids(room.id) : []
        selected, unselected = users.partition { member_ids.include?(it.id) }
      else
        selected, unselected = [], users
      end
      type_change_path = editing ? "/rooms/#{form_type == "open" ? "closeds" : "opens"}/#{room.id}/edit" : "/rooms/#{form_type == "open" ? "closeds" : "opens"}/new"
      view = build_view(room: room, editing: editing, form_type: form_type, can_administer: administer,
        room_name: editing ? room.name : "New room", type_change_path: type_change_path, user_count: users.size,
        selected_users: selected, unselected_users: unselected, last_room_visited: last_room_visited)
      render_layout(view, page_title: editing ? "Edit settings for #{room.name}" : "New chat room",
        nav: view.tpl_rooms_settings_nav, main: view.tpl_rooms_settings)
    end

    def reachable_message!(id)
      row = db.row(<<~SQL, current_user.id, id.to_i) or record_not_found!
        SELECT #{Message.columns} FROM messages INNER JOIN rooms ON messages.room_id = rooms.id
        INNER JOIN memberships ON rooms.id = memberships.room_id WHERE memberships.user_id = ? AND messages.id = ? LIMIT 1
      SQL
      Message.new(*row)
    end

    def room_scoped!(room_id)
      membership = repo.membership(current_user.id, room_id.to_i) or record_not_found!
      repo.room(membership.room_id)
    end

    def remember_last_room_visited(room)
      if request.cookies["last_room"] != room.id.to_s
        response.set_cookie("last_room", value: room.id.to_s, path: "/", expires: permanent_expiry, same_site: :lax)
      end
    end

    def last_room_visited
      (id = request.cookies["last_room"]) && repo.user_room(current_user.id, id.to_i) || repo.user_original_room(current_user.id)
    end

    def find_room_messages(room, message_id)
      if message_id && (anchor = repo.room_message(room.id, message_id.to_i))
        repo.page_before(room.id, anchor.created_at) + [ anchor ] + repo.page_after(room.id, anchor.created_at)
      else
        repo.last_page(room.id)
      end
    end

    def render_room(room, messages)
      fragment_page { render_room_page(room, messages) }
    end

    # A page whose message fragments go out as a FragmentBody (cached gzip blocks).
    def fragment_page
      @collect_fragments = true
      html = yield
      view = @fragment_view
      body = view&.fragments ? FragmentBody.from(html, view.fragments) : [ html ]
      headers "Content-Length" => body.is_a?(FragmentBody) ? body.bytesize.to_s : html.bytesize.to_s
      body
    ensure
      @collect_fragments = false
    end

    def render_room_page(room, messages)
      views = message_views(messages)
      invitation = room.id == repo.original_room_id && repo.room_message_count(room.id) <= Repo::PAGE_SIZE
      account = runtime.account
      page_etag("room", room, account.updated_at, account.name, invitation, messages.map { "#{it.id}-#{it.updated_at}" },
        (repo.direct_room_member_names(room.id, current_user.id) if room.direct?), flash_now)
      view = build_view(room: room, messages: views, invitation: invitation)
      render_layout(view,
        page_title: view.room_display_name(room), body_class: "sidebar",
        head: view.tpl_rooms_head, nav: view.tpl_rooms_nav, main: view.tpl_rooms_show, footer: view.tpl_rooms_composer,
        sidebar: sidebar_frame_tag)
    end

    def render_welcome
      view = build_view
      main = <<~HTML
        <div id="message-area" class="message-area">
          <div class="message-area--empty min-width center">
            <figure class="center pad">
              #{view.image_tag("messages-empty.svg", aria: { hidden: "true" }, class: "colorize--black translucent")}
              <span class="for-screen-reader">#{HTML.h(current_user.name)}</span>
            </figure>
          </div>
        </div>
      HTML
      render_layout(view, main: main, page_title: "No rooms yet", body_class: "sidebar", sidebar: sidebar_frame_tag)
    end

    def sidebar_frame_tag
      %(<turbo-frame data-turbo-permanent="true" data-controller="rooms-list read-rooms turbo-frame" data-rooms-list-unread-class="unread" data-action="presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload" id="user_sidebar" src="/users/me/sidebar" target="_top"></turbo-frame>)
    end

    def render_room_not_found
      html_headers("text/vnd.turbo-stream.html")
      %(<turbo-stream action="update" target="message-area"><template><div class="message-area--empty min-width center txt-medium">This room has been deleted.</div></template></turbo-stream>)
    end

    def messages_html(messages)
      fragment_page do
        view = build_view
        message_views(messages).map { view.render_message_cached(it) }.join
      end
    end

    # ActionController::ConditionalGet#fresh_when(@messages): the collection's cache key.
    def etag_for_messages(messages)
      page_etag("messages", messages.map { "#{it.id}-#{it.updated_at}" })
    end

    # The data each message partial needs, loaded only for messages not already in the fragment
    # cache (as Rails' collection caching does).
    def message_views(messages)
      Messages.views(self, messages)
    end

    # ---- Sidebar

    def render_sidebar
      memberships = repo.sidebar_memberships(current_user.id)
      directs, others = memberships.partition { |_, room| room.direct? }
      directs = directs.sort_by { |_, room| room.updated_at }.reverse.map do |membership, room|
        members = repo.room_users_except(room.id, current_user.id)
        members = [ current_user ] if members.empty?
        [ membership, room, members ]
      end

      exclude = repo.member_ids_of_rooms(repo.direct_room_ids(current_user.id)).uniq + [ current_user.id ]
      placeholders = repo.active_users_excluding(exclude, [ 20 - exclude.size, 0 ].max)

      view = build_view(direct_memberships: directs, other_memberships: others, placeholder_users: placeholders)
      render_layout(view, main: view.tpl_users_sidebar)
    end

    # ---- Searches

    def render_search(query, raw_query, messages)
      fragment_page { render_search_page(query, raw_query, messages) }
    end

    def render_search_page(query, raw_query, messages)
      views = message_views(messages)
      recent = repo.recent_search_queries(current_user.id)
      return_to_room = last_room_visited
      account = runtime.account
      page_etag("search", raw_query, account.updated_at, recent, return_to_room.id, messages.map { "#{it.id}-#{it.updated_at}" })
      view = build_view(query: query, raw_query: raw_query, count: messages.size, messages: views, recent_searches: recent,
        return_to_room: return_to_room)
      view.with(recents: view.tpl_searches_recents)
      render_layout(view, page_title: "Search", body_class: "sidebar searches",
        nav: view.tpl_searches_nav, main: view.tpl_searches_index, footer: view.tpl_searches_footer, sidebar: view.tpl_searches_sidebar)
    end

    # A numeric path segment, or the 404 an unmatched route gets (the reference's routes only match digits there).
    def id_param(name)
      value = params[name].to_s
      record_not_found! unless value.match?(/\A\d+\z/)
      value.to_i
    end
  end
end
