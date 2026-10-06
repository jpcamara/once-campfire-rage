require "user_agent"

module Campfire
  # app/models/application_platform.rb over platform_agent, on the same useragent gem.
  class Platform
    def initialize(user_agent_string)
      @string = user_agent_string
    end

    def ios? = match?(/iPhone|iPad/)
    def android? = match?(/Android/)
    def mac? = match?(/Macintosh/)
    def chrome? = browser_name.match?(/Chrome/)
    def firefox? = browser_name.match?(/Firefox|FxiOS/)
    def safari? = browser_name.match?(/Safari/)
    def edge? = browser_name.match?(/Edg/)
    def mobile? = ios? || android?
    def desktop? = !mobile?
    def windows? = operating_system == "Windows"

    def apple_messages?
      match?(/facebookexternalhit/i) && match?(/Twitterbot/i)
    end

    def browser
      user_agent.browser
    end

    def operating_system
      case user_agent.platform
      when /Android/   then "Android"
      when /iPad/      then "iPad"
      when /iPhone/    then "iPhone"
      when /Macintosh/ then "macOS"
      when /Windows/   then "Windows"
      when /CrOS/      then "ChromeOS"
      else
        os = user_agent.os
        os =~ /Linux/ ? "Linux" : os
      end
    end

    private
      def match?(pattern)
        @string.to_s.match?(pattern)
      end

      def browser_name
        browser.to_s
      end

      def user_agent
        @user_agent ||= UserAgent.parse(@string)
      end
  end
end
