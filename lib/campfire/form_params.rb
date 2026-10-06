module Campfire
  # Rage parses request bodies with Iodine, whose form parser rejects bodies Rack accepts, such as raw
  # UTF-8 (a bot's `curl -d '🎉'`), and fails on a body with no content type. When it gives up, parse
  # as Rack (and so Rails) would: still a 400 for what Rack rejects too.
  module FormParams
    def prepare(env, url_params)
      super
    rescue Rage::Errors::BadRequest
      type = env["CONTENT_TYPE"].to_s
      raise unless type.empty? || type.start_with?("application/x-www-form-urlencoded")
      begin
        query = Rack::Utils.parse_nested_query(env["QUERY_STRING"].to_s)
        input = env["rack.input"]&.tap(&:rewind)
        form = type.empty? || input.nil? ? {} : Rack::Utils.parse_nested_query(input.read.to_s.force_encoding(Encoding::UTF_8))
      rescue Rack::Utils::InvalidParameterError, Rack::Utils::ParameterTypeError, ArgumentError
        raise Rage::Errors::BadRequest
      end
      query.merge(form).merge(url_params)
    end
  end
end

Rage::ParamsParser.singleton_class.prepend(Campfire::FormParams)
