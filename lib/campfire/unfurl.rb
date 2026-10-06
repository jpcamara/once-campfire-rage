require "resolv"
require "ipaddr"
require "net/http"

module Campfire
  # UnfurlLinksController over Opengraph::Metadata: fetch a public page's og: tags, refusing
  # private addresses (RestrictedHTTP::PrivateNetworkGuard) at every redirect.
  module Unfurl
    ATTRIBUTES = %w[ title url image description ].freeze
    MAX_BODY_SIZE = 5 * 1024 * 1024
    MAX_REDIRECTS = 10
    TWITTER_HOSTS = %w[ twitter.com www.twitter.com x.com www.x.com ].freeze
    IMAGE_TYPES = %w[ image/jpeg image/png image/gif image/webp ].freeze
    FILES_AND_MEDIA = /\bhttps?:\/\/\S+\.(?:zip|tar|tar\.gz|tar\.bz2|tar\.xz|gz|bz2|rar|7z|dmg|exe|msi|pkg|deb|iso|jpg|jpeg|png|gif|bmp|mp4|mov|avi|mkv|wmv|flv|heic|heif|mp3|wav|ogg|aac|wma|webm|ogv|mpg|mpeg)\b/
    BLOCKED = %w[ 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24
      192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3 ::/128 ::1/128 ::ffff:0:0/96 64:ff9b::/96
      100::/64 2001:db8::/32 fc00::/7 fe80::/10 ff00::/8 ].map { IPAddr.new(it) }.freeze

    module_function

    # The metadata as JSON, or nil when it's incomplete (204 No Content).
    def metadata(url)
      fetch_url = tweet?(url) ? url.sub(%r{//(www\.)?(twitter|x)\.com}, "//fxtwitter.com") : url
      html = read_html(fetch_url) or return nil
      attributes = og_attributes(html)
      attributes["url"] = public_ip(attributes["url"]) ? attributes["url"] : url
      attributes["image"] = nil unless attributes["image"] && IMAGE_TYPES.include?(content_type(attributes["image"]).to_s.downcase)
      attributes["title"] = clean(attributes["title"])
      attributes["description"] = clean(attributes["description"])
      return nil if %w[ title url description ].any? { attributes[it].to_s.strip.empty? }
      # Rails renders the model's instance values, validation state included.
      ATTRIBUTES.to_h { [ it, attributes[it] ] }.merge("context_for_validation" => { "context" => nil }, "errors" => {})
    end

    def og_attributes(html)
      doc = Nokogiri::HTML(html)
      doc.xpath(%(//*/meta[starts-with(@property, "og:") or starts-with(@name, "og:")])).each_with_object({}) do |tag, attributes|
        key = tag.key?("property") ? "property" : "name"
        name = tag[key].delete_prefix("og:")
        attributes[name] = tag["content"] if ATTRIBUTES.include?(name) && !tag["content"].to_s.strip.empty?
      end
    end

    def clean(text)
      text && Rails::HTML5::FullSanitizer.new.sanitize(text.to_s)
    end

    def tweet?(url)
      uri = URI.parse(url)
      TWITTER_HOSTS.include?(uri.host) && !uri.path.to_s.empty? && uri.path != "/"
    rescue URI::InvalidURIError
      false
    end

    def read_html(url)
      return nil if url.match?(FILES_AND_MEDIA)
      request(url, Net::HTTP::Get) do |response|
        return nil unless response.is_a?(Net::HTTPOK) && response.content_type == "text/html" && response.content_length.to_i <= MAX_BODY_SIZE
        body = +""
        response.read_body { |chunk| return nil if body.bytesize + chunk.bytesize > MAX_BODY_SIZE; body << chunk }
        return body
      end
    rescue => error
      warn "unfurl failed: #{error.class}: #{error.message}"
      nil
    end

    def content_type(url)
      request(url, Net::HTTP::Head) { |response| return response["Content-Type"] }
    rescue
      nil
    end

    def request(url, request_class)
      uri = URI.parse(url)
      MAX_REDIRECTS.times do
        raise ArgumentError, "not http" unless uri.is_a?(URI::HTTP)
        ip = public_ip(uri.to_s) or raise ArgumentError, "not public"
        Net::HTTP.start(uri.host, uri.port, ipaddr: ip, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 5) do |http|
          http.request(request_class.new(uri)) do |response|
            if response.is_a?(Net::HTTPRedirection)
              uri = URI.parse(response["location"])
            else
              yield response
              return nil
            end
          end
        end
      end
      nil
    end

    def public_ip(url)
      uri = URI.parse(url.to_s)
      return nil unless uri.is_a?(URI::HTTP) && uri.host
      Resolv.getaddresses(uri.host).find { |address| BLOCKED.none? { it.include?(IPAddr.new(address)) } }
    rescue URI::InvalidURIError, IPAddr::InvalidAddressError
      nil
    end
  end
end
