Rage.configure do
  config.server.port = ENV.fetch("HTTP_PORT", 3000).to_i
  config.server.workers_count = ENV.fetch("WEB_CONCURRENCY", 1).to_i
  config.logger = Rage::Logger.new(STDOUT)
  config.log_level = Logger::INFO
end
