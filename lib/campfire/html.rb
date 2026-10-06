require "cgi/escape"
require "json"

module Campfire
  # Rails' tag helpers, reduced to what the templates use: attribute rendering (with data/aria
  # hashes expanded and dasherized, booleans as name="name"), escaping and asset paths.
  module HTML
    BOOLEAN_ATTRIBUTES = %w[ allowfullscreen allowpaymentrequest async autofocus autoplay checked compact controls declare default
      defaultchecked defaultmuted defaultselected defer disabled enabled formnovalidate hidden indeterminate inert ismap
      itemscope loop multiple muted nohref nomodule noresize noshade novalidate nowrap open pauseonexit playsinline
      readonly required reversed scoped seamless selected sortable truespeed typemustmatch visible ].to_h { [ it, true ] }.freeze

    module_function

    def h(value)
      CGI.escapeHTML(value.to_s)
    end

    def attributes(attrs)
      out = +""
      attrs.each do |key, value|
        next if value.nil?
        key = key.to_s
        if (key == "data" || key == "aria") && value.is_a?(Hash)
          value.each do |k, v|
            next if v.nil?
            v = v.is_a?(String) || v.is_a?(Symbol) || v.is_a?(Numeric) || v == true || v == false ? v.to_s : v.to_json
            out << " " << key << "-" << k.to_s.tr("_", "-") << "=\"" << h(v) << "\""
          end
        elsif BOOLEAN_ATTRIBUTES[key]
          out << " " << key << "=\"" << key << "\"" if value
        else
          value = value.join(" ") if value.is_a?(Array)
          out << " " << key << "=\"" << h(value) << "\""
        end
      end
      out
    end

    def tag(name, content = nil, **attrs)
      "<#{name}#{attributes(attrs)}>#{content}</#{name}>"
    end

    def void_tag(name, **attrs)
      "<#{name}#{attributes(attrs)} />"
    end
  end

  # ActiveSupport::JSON.encode: HTML-unsafe characters escaped as \uXXXX.
  module RailsJSON
    ESCAPES = { "<" => "\\u003c", ">" => "\\u003e", "&" => "\\u0026", "\u2028" => "\\u2028", "\u2029" => "\\u2029" }.freeze

    def self.generate(object)
      JSON.generate(object).gsub(/[<>&\u2028\u2029]/, ESCAPES)
    end
  end

  # Propshaft's digested asset paths, from public/assets/.manifest.json.
  module Assets
    @paths = {}

    class << self
      def load(root)
        manifest = JSON.parse(File.read(File.join(root, "public/assets/.manifest.json")))
        @paths = manifest.to_h { |logical, entry| [ logical, "/assets/#{entry["digested_path"]}".freeze ] }
        head = File.read(File.join(root, "views/_head_assets.html"))
        split = head.index('<script type="importmap"')
        @stylesheets, @javascripts = head[0...split].rstrip.freeze, head[split..].freeze
        @link_header = File.read(File.join(root, "views/_link_header.txt")).strip.freeze
      end

      def path(logical)
        @paths.fetch(logical) { "/#{logical}" }
      end

      attr_reader :stylesheets, :javascripts, :link_header
    end
  end
end
