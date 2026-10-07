require "bundler/setup"
require "rage"
Bundler.require(*Rage.groups)

require "rage/all"

require_relative "../lib/campfire"

Rage.configure do
  config.cable.protocol = Campfire::CableProtocol
  # Jobs run in this process, in memory, as the Rust port's do.
  config.deferred.backend = nil

  # The real clock's Date under the parity harness's faked one, assume_ssl and force_ssl (unless
  # DISABLE_SSL), the forms' method override, Thruster's response cache and gzip, Rails' Rack::ETag,
  # digested assets from memory, and X-Request-Id for everything the app answers.
  config.middleware.use Campfire::RealDate if Campfire::RealDate.wrap?
  if Campfire::SSL.enabled?
    config.middleware.use Campfire::SSL::Assume
    config.middleware.use Campfire::SSL::Force
  end
  config.middleware.use Campfire::RequestMethod
  config.middleware.use Campfire::ResponseCache
  config.middleware.use Campfire::Compression
  config.middleware.use Campfire::ETag
  config.middleware.use Campfire::AssetFiles
  config.middleware.use Campfire::RequestId
end

require "rage/setup"
