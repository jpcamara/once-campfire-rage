require "bcrypt"
require "ipaddr"
require "rack"

module Campfire
  # What every Campfire controller shares: the request and response helpers the actions use, the
  # Rails behaviors that wrap every action (default headers, browser gating, banned IPs), and the
  # authentication, session and flash helpers.
  #
  # An action is declared with `action :name do ... end`. Its block returns the response body, and
  # `halt`, `redirect` and the helpers built on them end it early, so actions read as a sequence of
  # guards and a render.
  module Web
    PERMANENT_YEARS = 20
    SESSION_REFRESH = 3600

    SECURITY_HEADERS = { "x-frame-options" => "SAMEORIGIN", "x-xss-protection" => "0", "x-content-type-options" => "nosniff",
      "x-permitted-cross-domain-policies" => "none", "referrer-policy" => "strict-origin-when-cross-origin" }.freeze

    TRUSTED_PROXIES = %w[ 127.0.0.0/8 ::1/128 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 fc00::/7 ].map { IPAddr.new(it) }.freeze

    NO_BODY_STATUSES = [ 204, 304 ].freeze
    TEXT_TYPES = %r{\Atext/|\Aapplication/(javascript|xml|xhtml\+xml)\z}

    Halt = Data.define(:args)

    # The request as Rack sees it, with the one Accept helper the actions use.
    class Request < Rack::Request
      def first_accepted_type
        get_header("HTTP_ACCEPT").to_s.split(",").first.to_s.split(";").first.to_s.strip
      end
    end

    # The response's headers and cookies.
    class Response
      attr_reader :headers

      def initialize(headers)
        @headers = headers
      end

      def [](name) = @headers[name]
      def []=(name, value)
        @headers[name] = value
      end

      def set_cookie(name, options)
        Rack::Utils.set_cookie_header!(@headers, name, options)
      end

      def delete_cookie(name, options = {})
        Rack::Utils.delete_set_cookie_header!(@headers, name, options)
      end
    end

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def action(name, &block)
        define_method(:"#{name}_body", &block)
        private :"#{name}_body"
        define_method(name) { respond { send(:"#{name}_body") } }
      end
    end

    def runtime = Campfire.runtime
    def repo = runtime.repo
    def db = runtime.db
    def secrets = runtime.secrets

    def request = (@request ||= Request.new(@__env))
    def response = (@response ||= Response.new(@__headers))
    def env = @__env

    # Rails' params: string keys, UTF-8 values (Iodine parses into binary strings, which SQLite would
    # bind as blobs), uploads as { tempfile:, filename:, type: }.
    def params
      @params ||= Web.stringify_params(@__params)
    end

    def self.stringify_params(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), hash| hash[key.to_s] = stringify_params(item) unless key == :controller || key == :action }
      when Array then value.map { stringify_params(it) }
      when String then value.encoding == Encoding::UTF_8 ? value : value.dup.force_encoding(Encoding::UTF_8)
      when Rage::UploadedFile then { tempfile: value.file, filename: value.original_filename.to_s.dup.force_encoding(Encoding::UTF_8), type: value.content_type }
      else value
      end
    end

    # ---- Responding

    def respond
      @__headers = Rack::Headers.new
      @status = 200
      result = catch(:halt) do
        apply_default_headers
        yield
      end
      finish(result)
    rescue => error
      warn "#{error.class}: #{error.message}\n#{error.backtrace&.first(10)&.join("\n")}"
      @__headers = Rack::Headers.new
      @status = 500
      @__headers["content-type"] = "text/html; charset=utf-8"
      finish(Campfire.file_io { File.read(File.join(ROOT, "public/500.html")) })
    end

    # ActionDispatch's default headers on every controller response, ApplicationController's
    # VersionHeaders, AllowBrowser and BlockBannedRequests.
    def apply_default_headers
      @__headers.merge!(SECURITY_HEADERS)
      @__headers["x-version"] = runtime.app_version
      @__headers["x-rev"] = runtime.git_revision.to_s
      return if request.path_info.start_with?("/rails/active_storage", "/up")
      halt render_incompatible_browser if Browsers.blocked?(request.user_agent)
      head_response(429) if !(request.get? || request.head?) && db.value("SELECT 1 FROM bans WHERE ip_address = ? LIMIT 1", remote_ip)
    end

    def status(code = nil)
      @status = code if code
      @status
    end

    def headers(hash = nil)
      @__headers.merge!(hash) if hash
      @__headers
    end

    def body(value)
      @body = value.respond_to?(:each) ? value : [ value.to_s ]
    end

    def halt(*args)
      throw :halt, Halt.new(args.size == 1 ? args.first : args)
    end

    # A route's result: a body, a status, or [status, headers, body].
    def apply(result)
      result = result.args if result.is_a?(Halt)
      result = [ result ] if result.is_a?(Integer) || result.is_a?(String)
      if result.is_a?(Array) && result.first.is_a?(Integer)
        result = result.dup
        status(result.shift)
        value = result.pop
        body(value) unless value.nil?
        result.each { headers(it) }
      elsif result.respond_to?(:each)
        body(result)
      end
    end

    def finish(result)
      apply(result)
      # ActionDispatch::Response's default Cache-Control: revalidation only for responses with an
      # ETag or Last-Modified (Rack::ETag adds one to 200s), no-cache for the rest.
      if @__headers["cache-control"] == "max-age=0, private, must-revalidate" && @status != 200
        @__headers["cache-control"] = "no-cache"
      end
      @__headers["cache-control"] ||= "no-cache" if @status == 204 # head :no_content
      @__headers["content-type"] ||= "text/html;charset=utf-8"
      body = @body || []
      if NO_BODY_STATUSES.include?(@status)
        @__headers.delete("content-type")
        @__headers.delete("content-length")
        body = []
      elsif body.is_a?(Array) && !@__headers["content-length"]
        @__headers["content-length"] = body.sum(&:bytesize).to_s
      end
      @__status, @__body, @__rendered = @status, body, true
    end

    # Rails' redirect_to: always 302.
    def redirect(uri, *args)
      status 302
      @__headers["location"] = uri
      headers "content-type" => "text/html; charset=utf-8"
      @__headers["cache-control"] ||= "no-cache"
      halt(*args)
    end

    # Sinatra's etag: the header, and a 304 when the client has it.
    def etag(value, kind: :strong)
      value = %("#{value}")
      value = "W/#{value}" if kind == :weak
      @__headers["etag"] = value
      return unless (200..299).cover?(@status) || @status == 304
      if env["HTTP_IF_NONE_MATCH"].to_s.split(",").map(&:strip).include?(value)
        halt(request.get? || request.head? ? 304 : 412)
      end
    end

    # Sinatra's send_file, through Rack::Files (byte ranges included).
    def send_file(path, type:, disposition: nil)
      type = Rack::Mime.mime_type(File.extname(path), "application/octet-stream") if type.nil?
      type = "#{type};charset=utf-8" if type.match?(TEXT_TYPES) && !type.include?("charset")
      headers "content-type" => type
      @__headers["content-disposition"] = disposition.to_s if disposition
      status_code, file_headers, file_body = Rack::Files.new(File.dirname(path)).serving(request, path)
      file_headers.each { |name, value| @__headers[name] ||= value }
      @__headers["content-length"] = file_headers["content-length"]
      halt status_code, Campfire.file_io { (+"").b.tap { |content| file_body.each { content << it } } }
    rescue Errno::ENOENT
      record_not_found!
    end

    # ---- Requests

    # ActionDispatch::RemoteIp: the client is the last X-Forwarded-For address that isn't a trusted
    # proxy, when the request came through one.
    def remote_ip
      @remote_ip ||= begin
        normalize = ->(ip) { ip.to_s.strip.delete_prefix("::ffff:") }
        trusted = ->(ip) { (addr = IPAddr.new(ip) rescue nil) && TRUSTED_PROXIES.any? { it.include?(addr) } }
        remote = normalize.(env["REMOTE_ADDR"])
        forwarded = env["HTTP_X_FORWARDED_FOR"].to_s.split(",").map(&normalize).reject(&:empty?).reverse
        if !forwarded.empty? && trusted.(remote)
          forwarded.find { !trusted.(it) } || forwarded.last
        else
          remote
        end
      end
    end

    def current_user = @current_user
    def base_url = (@base_url ||= "#{request.scheme}://#{request.host_with_port}")
    def url_for(path) = "#{base_url}#{path}"

    def build_view(**locals)
      view = View.new(app: runtime, current_user: current_user, base_url: base_url, user_agent: request.user_agent, flash: flash_now)
        .with(referrer: request.referer, request_url: request.url, **locals)
      if @collect_fragments && !@fragment_view
        @fragment_view = view
        view.collecting_fragments { }
      end
      view
    end

    def html_headers(type = "text/html")
      headers "cache-control" => "max-age=0, private, must-revalidate", "content-type" => "#{type}; charset=utf-8"
      headers "vary" => "Accept" if vary_by_accept?
    end

    # ActionDispatch::Request#should_apply_vary_header?: only when the format came from a
    # non-browser Accept header.
    def vary_by_accept?
      accept = env["HTTP_ACCEPT"].to_s
      params["format"].to_s.empty? && !accept.empty? && !accept.match?(/,\s*\*\/\*|\*\/\*\s*,/)
    end

    def without_version_headers
      @__headers.delete("x-version")
      @__headers.delete("x-rev")
    end

    # Avatars and the account logo go out without ActionDispatch's default headers, as Rails sends them.
    def without_security_headers
      SECURITY_HEADERS.each_key { @__headers.delete(it) }
    end

    # send_file as ActionController::DataStreaming writes it.
    def send_inline_file(path, type)
      without_security_headers
      headers "content-type" => type, "content-transfer-encoding" => "binary",
        "content-disposition" => Storage.content_disposition("inline", File.basename(path))
      Campfire.file_io { File.binread(path) }
    end

    # The ETag of a page built from cached message fragments: everything it's rendered from.
    def page_etag(*parts)
      headers "etag" => %(W/"#{Digest::MD5.hexdigest([ base_url, request.user_agent, current_user&.id, current_user&.updated_at, current_user&.role, *parts ].join("|"))}")
    end

    # frame_layout: false for MessagesController, whose `layout false, only: :index` replaces
    # turbo-rails' frame layout, so its other actions render the application layout for frames too.
    def render_layout(view, main:, page_title: nil, body_class: nil, head: nil, nav: nil, footer: nil, sidebar: nil, frame_layout: true)
      html_headers
      # Turbo::Frames::FrameRequest: frame requests get turbo-rails' bare frame layout.
      if frame_layout && env["HTTP_TURBO_FRAME"].to_s != ""
        return "<html>\n  <head>\n    \n    #{head}\n  </head>\n  <body>\n    #{main}\n  </body>\n</html>\n"
      end

      view.with(page_title: page_title, body_class: body_class, content_head: head, content_nav: nav, content_main: main,
        content_footer: footer, content_sidebar: sidebar)
      headers "link" => Assets.link_header
      view.tpl_layouts_application
    end

    def render_page(template, page_title: nil, head: nil, body_class: nil, **locals)
      view = build_view(**locals)
      render_layout(view, main: view.public_send(:"tpl_#{template}"), page_title: page_title, head: head, body_class: body_class)
    end

    def flash_now
      @flash ||= read_flash
    end

    def render_sign_in_rejection(code)
      flash_now["alert"] = "Too many requests or unauthorized."
      status code
      render_page(:sessions_new, page_title: "Sign in", head: %(<meta name="turbo-visit-control" content="reload">), email_address: params["email_address"])
    end

    def render_incompatible_browser
      view = build_view
      render_layout(view, main: view.tpl_sessions_incompatible_browser,
        page_title: Platform.new(request.user_agent).apple_messages? ? "Campfire" : "Unsupported browser")
    end

    def signed_blob!(signed_id)
      id = Storage.find_signed_blob_id(runtime, signed_id) or active_storage_not_found
      row = db.row("SELECT #{Blob.columns} FROM active_storage_blobs WHERE id = ?", id) or active_storage_not_found
      Blob.new(*row)
    end

    # ActionController::Head#head: no body, no-cache. Rails sets the controller's formats only after
    # the before-actions, so a head from one is text/html; inside an action it's the request's format.
    def head_response(code, in_action: false)
      turbo = in_action && env["HTTP_ACCEPT"].to_s.start_with?("text/vnd.turbo-stream.html")
      halt code, { "content-type" => turbo ? "text/vnd.turbo-stream.html" : "text/html", "cache-control" => "no-cache" }, ""
    end

    # ActiveRecord::RecordNotFound from a find: the public 404 page, as ActionDispatch::ShowExceptions
    # serves it (none of the controller's headers).
    def record_not_found!
      without_security_headers
      without_version_headers
      halt 404, { "content-type" => "text/html; charset=UTF-8" }, Campfire.file_io { File.read(File.join(ROOT, "public/404.html")) }
    end

    # Active Storage's controllers aren't ApplicationControllers: a missing blob is the public 404
    # page, without version headers.
    def active_storage_not_found
      without_version_headers
      halt 404, { "content-type" => "text/html", "cache-control" => "no-cache" }, Campfire.file_io { File.read(File.join(ROOT, "public/404.html")) }
    end

    # ActiveStorage::Blobs::RedirectController and Representations::RedirectController
    def redirect_to_disk(blob, disposition)
      without_version_headers
      disposition = Storage.forced_disposition_for_serving(blob.content_type) || (disposition == "attachment" ? "attachment" : "inline")
      headers "cache-control" => "max-age=300, private"
      redirect url_for(Storage.disk_path(runtime, key: blob.key, filename: blob.filename,
        content_type: Storage.content_type_for_serving(blob.content_type),
        disposition: Storage.content_disposition(disposition, blob.filename)))
    end

    # ---- Authentication

    def restore_authentication
      return @current_user if defined?(@current_user) && @current_user
      raw = request.cookies["session_token"] or return nil
      token = secrets.verify_cookie("session_token", raw) or return nil
      session = repo.session_by_token(token) or return nil
      user = repo.user(session.user_id) or return nil
      resume_session(session)
      @session = session
      @current_user = user
    end

    def require_authentication!
      return if restore_authentication

      if request.get? || request.head?
        write_session("return_to_after_authenticating" => request.url)
      end
      halt redirect(url_for("/session/new"))
    end

    def resume_session(session)
      if TimeFormat.parse(session.last_active_at) < Time.now - SESSION_REFRESH
        now = TimeFormat.now_text
        db.transaction do |w|
          w.run("UPDATE sessions SET user_agent = ?, ip_address = ?, last_active_at = ?, updated_at = ? WHERE id = ?",
            request.user_agent, remote_ip, now, now, session.id)
        end
        set_session_cookie(session.token)
      end
    end

    def start_new_session_for(user)
      token = Tokens.base58(24)
      now = TimeFormat.now_text
      db.transaction do |w|
        w.run("INSERT INTO sessions (created_at, ip_address, last_active_at, token, updated_at, user_agent, user_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
          now, remote_ip, now, token, now, request.user_agent, user.id)
      end
      set_session_cookie(token)
      @current_user = user
    end

    def set_session_cookie(token)
      expires = permanent_expiry
      response.set_cookie("session_token", value: secrets.sign_cookie("session_token", token, expires), path: "/",
        expires: expires, httponly: true, same_site: :lax)
    end

    def permanent_expiry
      now = Time.now.utc
      Time.utc(now.year + PERMANENT_YEARS, now.month, now.day, now.hour, now.min, now.sec, now.usec)
    end

    def redirect_after_authentication
      session = read_session
      target = session.delete("return_to_after_authenticating")
      write_session(session) if target
      redirect target || url_for("/")
    end

    # ---- The Rails session cookie, used here only for flash and the post-login redirect.

    def read_session
      raw = request.cookies["_campfire_session"]
      (raw && secrets.decrypt_cookie("_campfire_session", raw)) || {}
    end

    def write_session(hash)
      if hash.empty?
        response.delete_cookie("_campfire_session", path: "/")
      else
        expires = Time.now.utc + PERMANENT_YEARS * 365.25 * 86_400
        response.set_cookie("_campfire_session", value: secrets.encrypt_cookie("_campfire_session", hash, expires), path: "/",
          expires: expires, httponly: true, same_site: :lax)
      end
    end

    def read_flash
      return {} unless request.cookies["_campfire_session"]
      session = read_session
      flash = session.delete("flash")
      return {} unless flash
      write_session(session)
      (flash["flashes"] || {}).reject { |key, _| Array(flash["discard"]).include?(key) }
    end

    def redirect_with_alert(path, alert) = redirect_with_flash(path, "alert", alert)
    def redirect_with_notice(path, notice) = redirect_with_flash(path, "notice", notice)

    def redirect_with_flash(path, key, message)
      session = read_session
      session["flash"] = { "discard" => [], "flashes" => { key => message } }
      write_session(session)
      redirect url_for(path)
    end

    # Sec-Fetch-Site replaces CSRF tokens, as in the Rust port (kit/src/ctx.rs
    # verify_authenticity_token): the Origin, if sent, must be this app's (a "null" one is
    # rejected); then same-origin and same-site writes pass, and a missing header passes only when
    # neither the request nor the app uses SSL. Anything else is InvalidAuthenticityToken: the public
    # 422 page, as ActionDispatch::ShowExceptions serves it.
    def verify_same_origin!
      origin = env["HTTP_ORIGIN"]
      valid_origin = origin.nil? || (origin != "null" && origin == base_url)
      valid_site =
        case env["HTTP_SEC_FETCH_SITE"]
        when "same-origin", "same-site" then true
        when nil then request.scheme != "https" && !SSL.enabled?
        else false
        end
      unprocessable_entity! unless valid_origin && valid_site # ActionController::InvalidAuthenticityToken
    end

    def unprocessable_entity!
      without_security_headers
      without_version_headers
      halt 422, { "content-type" => "text/html; charset=UTF-8" }, Campfire.file_io { File.read(File.join(ROOT, "public/422.html")) }
    end
  end
end
