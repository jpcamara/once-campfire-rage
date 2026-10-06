Rage.configure do
  config.server.port = ENV.fetch("HTTP_PORT", 80).to_i
  config.server.workers_count = ENV.fetch("WEB_CONCURRENCY") { Etc.nprocessors }.to_i
  # No request log, as in TechEmpower's setup; RAGE_LOG=1 turns it on for debugging.
  config.logger = ENV["RAGE_LOG"] ? Rage::Logger.new(STDOUT) : nil
end
