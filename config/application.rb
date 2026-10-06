require "bundler/setup"
require "rage"
Bundler.require(*Rage.groups)

require "rage/all"

require_relative "../lib/campfire"

Rage.configure do
  config.cable.protocol = Campfire::CableProtocol
  # Jobs run in this process, in memory, as the Rust port's do.
  config.deferred.backend = nil

  # Thruster's gzip and Rails' Rack::ETag, the forms' method override, digested assets from memory.
  config.middleware.use Campfire::RequestMethod
  config.middleware.use Campfire::Compression
  config.middleware.use Campfire::ETag
  config.middleware.use Campfire::AssetFiles
end

require "rage/setup"
