Rage.configure do
  config.server.port = ENV.fetch("HTTP_PORT", 80).to_i
  config.server.workers_count = ENV.fetch("WEB_CONCURRENCY") { Etc.nprocessors }.to_i
  config.logger = nil
end
