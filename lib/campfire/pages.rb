module Campfire
  # Helpers shared by the room, message, sidebar and search actions.
  module Pages
    # Authentication's restore_authentication || bot_authentication, then the user's room. A request
    # signed in by its session cookie is checked for forgery like any other write; only one
    # authenticated by its bot key skips the check (protect_from_forgery ... unless:
    # authenticated_by.bot_key?).
    def bot_room!(bot_key, room_id)
      if (bot = restore_authentication)
        verify_same_origin! unless request.get? || request.head?
      else
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
      invitation = room.id == repo.original_room_id && repo.room_message_count(room.id) <= Repo::PAGE_SIZE
      account = runtime.account
      direct_names = (repo.direct_room_member_names(room.id, current_user.id) if room.direct?)
      message_keys = messages.map { "#{it.id}-#{it.updated_at}" }
      page_etag("room", room, account.updated_at, account.name, invitation, message_keys, direct_names, flash_now)
      views = message_views(messages)
      shell_page([ :room, room, invitation, direct_names, runtime.account_logo_attached?, message_keys ], views) do
        render_room_page(room, views, invitation)
      end
    end

    # The page around its messages, memoized by a digest of everything its templates read, as the
    # Elixir port's room_page.ex and searches.ex do: the user, the account (name, logo, custom
    # styles, join code), the host, the user agent (platform-specific markup), the frame and Accept
    # headers, the flash, and the inputs the action passes. The messages are spliced in from their
    # cached fragments on every request, so a page is assembled for each request; nothing keeps a
    # finished response. With CAMPFIRE_CHECK_CACHES=1 a hit renders again and logs any mismatch.
    SHELLS = {}
    SHELLS_LIMIT = 512
    SHELL_HEADERS = %w[ cache-control content-type vary link ].freeze
    CHECK_CACHES = ENV["CAMPFIRE_CHECK_CACHES"]
    Shell = Data.define(:html, :headers)

    def shell_page(inputs, views, &render)
      key = Digest::SHA256.digest(Marshal.dump([ inputs, current_user, runtime.account, base_url, request.user_agent,
        env["HTTP_TURBO_FRAME"], env["HTTP_ACCEPT"], flash_now ]))
      fragment_view = build_view
      fragments = views.map { fragment_view.message_fragment(it) }
      if !Campfire.rust_caching_only? && (shell = SHELLS.delete(key))
        SHELLS[key] = shell
        headers shell.headers
        check_shell(shell, &render) if CHECK_CACHES
      else
        html = collecting_fragments(&render)
        shell = Shell.new(html.freeze, headers.slice(*SHELL_HEADERS).to_h.freeze)
        SHELLS[key] = shell unless flash_now.any? || Campfire.rust_caching_only?
        SHELLS.delete(SHELLS.first[0]) while SHELLS.size > SHELLS_LIMIT
      end
      body = FragmentBody.from(shell.html, fragments)
      headers "Content-Length" => body.bytesize.to_s
      body
    end

    def check_shell(shell, &render)
      fresh = collecting_fragments(&render)
      warn "CACHE MISMATCH #{request.path_info} (shell #{shell.html.bytesize} kept vs #{fresh.bytesize} fresh bytes)" unless fresh == shell.html
    end

    def collecting_fragments
      @collect_fragments = true
      yield
    ensure
      @collect_fragments = false
      @fragment_view = nil
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

    def render_room_page(room, views, invitation)
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

    # MessagesController#create's `render action: :room_not_found`: the HTML template in the
    # application layout, whose composer frame the submitting frame takes.
    def render_room_not_found
      view = build_view
      render_layout(view, main: view.tpl_messages_room_not_found, frame_layout: false)
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
      directs = directs.sort_by { |_, room| room.updated_at }.reverse

      exclude = repo.member_ids_of_rooms(repo.direct_room_ids(current_user.id)).uniq + [ current_user.id ]
      placeholders = repo.active_users_excluding(exclude, [ 20 - exclude.size, 0 ].max)

      view = build_view(other_memberships: others, placeholder_users: placeholders)
      view = view.with(direct_memberships: cached_sidebar_directs(view, directs))
      render_layout(view, main: view.tpl_users_sidebar)
    end

    # `render partial: "users/sidebars/rooms/direct", collection: ..., cached: true`: the Redis cache
    # store, keyed by the membership's id and updated_at. PresenceChannel marks a room read with
    # update_all, which leaves updated_at alone, so a room read since its fragment was cached still
    # shows unread here until a broadcast updates it.
    def cached_sidebar_directs(view, directs)
      return [] if directs.empty?
      keys = directs.map { |membership, _| "views/users/sidebars/rooms/_direct/memberships/#{membership.id}-#{membership.updated_at}" }
      cached = Redis.call("MGET", *keys)
      directs.each_with_index.map do |(membership, room), index|
        next cached[index].force_encoding(Encoding::UTF_8) if cached[index]
        members = repo.room_users_except(room.id, current_user.id)
        members = [ current_user ] if members.empty?
        view.render_sidebar_direct(membership, room, members).tap { Redis.call("SET", keys[index], it) }
      end
    end

    # ---- Searches

    def render_search(query, raw_query, messages)
      recent = repo.recent_search_queries(current_user.id)
      return_to_room = last_room_visited
      account = runtime.account
      message_keys = messages.map { "#{it.id}-#{it.updated_at}" }
      page_etag("search", raw_query, account.updated_at, recent, return_to_room.id, message_keys)
      views = message_views(messages)
      shell_page([ :search, query, raw_query, recent, return_to_room, runtime.account_logo_attached?, message_keys ], views) do
        render_search_page(query, raw_query, views, recent, return_to_room)
      end
    end

    def render_search_page(query, raw_query, views, recent, return_to_room)
      view = build_view(query: query, raw_query: raw_query, count: views.size, messages: views, recent_searches: recent,
        return_to_room: return_to_room)
      view.with(recents: view.tpl_searches_recents)
      render_layout(view, page_title: "Search", body_class: "sidebar searches",
        nav: view.tpl_searches_nav, main: view.tpl_searches_index, footer: view.tpl_searches_footer, sidebar: view.tpl_searches_sidebar)
    end

    # A record id from the path, cast as Active Record casts it: the reference's routes take any
    # segment, and an id that isn't a number finds nothing.
    def id_param(name)
      params[name].to_s.to_i
    end
  end
end
