require "json"
require "uri"
require "ipaddr"
require "digest"
require "delegate"
require "net/http"
require "tempfile"
require "redis-client"

require_relative "campfire/rails_compat"
require_relative "campfire/time_format"
require_relative "campfire/db"
require_relative "campfire/models"
require_relative "campfire/html"
require_relative "campfire/platform"
require_relative "campfire/sound"
require_relative "campfire/rich_text"
require_relative "campfire/repo"
require_relative "campfire/storage"
require_relative "campfire/attachments"
require_relative "campfire/uploads"
require_relative "campfire/translations"
require_relative "campfire/view"
require_relative "campfire/broadcasts"
require_relative "campfire/messages"
require_relative "campfire/support"
require_relative "campfire/memberships"
require_relative "campfire/runtime"
require_relative "campfire/web"
require_relative "campfire/pages"
require_relative "campfire/cable_protocol"
require_relative "campfire/fragment_body"
require_relative "campfire/compression"
require_relative "campfire/etag"
require_relative "campfire/unfurl"
require_relative "campfire/static_files"
require_relative "campfire/request_method"
require_relative "campfire/form_params"

module Campfire
  def self.boot
    Assets.load(ROOT)
    View.compile(ROOT)
  end

  # Local file IO outside the fiber scheduler. Rage hands reads to Iodine, which waits for a readiness
  # event between 64 KB chunks of a regular file; on an idle server that event only comes with the
  # next unrelated request, so a larger file stalls the request reading it. Plain blocking reads of
  # local files are what the other servers do.
  def self.file_io(&) = Fiber.blocking(&)

  # Process-wide state: the database, secrets and caches. Opened lazily, after Iodine forks.
  def self.runtime
    return @runtime if @runtime_pid == Process.pid
    @runtime_pid = Process.pid
    @runtime = Runtime.new
  end
end
