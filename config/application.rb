require "bundler/setup"
require "rage"
Bundler.require(*Rage.groups)

require "rage/all"

require_relative "../lib/campfire"

Rage.configure do
  config.cable.protocol = Campfire::CableProtocol
  # Jobs run in this process, in memory, as the Rust port's do.
  config.deferred.backend = nil

  # The real clock's Date under the parity harness's faked one, the forms' method override,
  # Thruster's response cache and gzip, Rails' Rack::ETag, digested assets from memory.
  config.middleware.use Campfire::RealDate if Campfire::RealDate.wrap?
  config.middleware.use Campfire::RequestMethod
  config.middleware.use Campfire::ResponseCache
  config.middleware.use Campfire::Compression
  config.middleware.use Campfire::ETag
  config.middleware.use Campfire::AssetFiles
end

require "rage/setup"
