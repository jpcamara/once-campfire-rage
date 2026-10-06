require "nokogiri"
require "rails-html-sanitizer"

module Campfire
  # MessagesHelper#message_presentation for text messages: the content filters
  # (app/helpers/content_filters), Action Text's attachment rendering and sanitizer, the
  # lexxy-content layout, then rails_autolink's auto_link. Uses the same sanitizer gems as Rails,
  # with the allow lists the Rails app ends up with at runtime.
  module RichText
    ATTACHMENT_TAG = "action-text-attachment"
    OPENGRAPH_CONTENT_TYPE = "application/vnd.actiontext.opengraph-embed"
    EDITOR_FORMATTING_TAGS = %w[ s u mark table thead tbody tfoot tr th td ].freeze

    SAFE_LIST_TAGS = Rails::HTML5::SafeListSanitizer.allowed_tags.to_a.freeze
    SAFE_LIST_ATTRIBUTES = Rails::HTML5::SafeListSanitizer.allowed_attributes.to_a.freeze
    ATTACHMENT_ATTRIBUTES = %w[ sgid content-type url href filename filesize width height previewable presentation caption content ].freeze

    # ContentFilters::SanitizeTags::ALLOWED_TAGS
    FILTER_TAGS = (%w[ a abbr acronym address b big blockquote br cite code dd del dfn div dl dt em h1 h2 h3 h4 h5 h6 hr i ins kbd li ol
      p pre samp small span strong sub sup time tt ul var ] + EDITOR_FORMATTING_TAGS + [ ATTACHMENT_TAG, "figure", "figcaption" ]).freeze
    FILTER_TAGS_SELECTOR = FILTER_TAGS.map { ":not(#{it})" }.join.freeze

    # ActionText::ContentHelper.allowed_tags / allowed_attributes as lib/rails_ext/action_text_allowed_tags.rb leaves them
    ACTION_TEXT_TAGS = %w[ a abbr acronym action-text-attachment address audio b big blockquote br cite code dd del dfn div dl dt em embed
      figcaption figure h1 h2 h3 h4 h5 h6 hr i img ins kbd li mark ol p pre s samp small source span strong sub sup table tbody td tfoot
      th thead time tr tt u ul var video ].freeze
    ACTION_TEXT_ATTRIBUTES = %w[ abbr alt caption cite class content content-type controls data-language datetime filename filesize height
      href lang name poster presentation previewable sgid src start style title url value width xml:lang ].freeze

    # ContentFilters::SanitizeAttributes: Action Text's allowed attributes plus class
    FILTER_ATTRIBUTES = (ACTION_TEXT_ATTRIBUTES + %w[ class ]).uniq.freeze

    # MessagesHelper::AUTO_LINK_ALLOWED_TAGS / _ATTRIBUTES
    AUTO_LINK_TAGS = (SAFE_LIST_TAGS + EDITOR_FORMATTING_TAGS).freeze
    AUTO_LINK_ATTRIBUTES = (SAFE_LIST_ATTRIBUTES + %w[ data-language ]).freeze

    AUTO_LINK_RE = %r{
        (?: ((?:ed2k|ftp|http|https|irc|mailto|news|gopher|nntp|telnet|webcal|xmpp|callto|feed|svn|urn|aim|rsync|tag|ssh|sftp|rtsp|afs|file):)// | www\.\w )
        [^\s< "]+
      }ix
    AUTO_LINK_CRE = [ /<[^>]+$/, /^[^>]*>/, /<a\b.*?>/i, /<\/a>/i ].freeze
    AUTO_EMAIL_LOCAL_RE = /[\w.!#\$%&'*\/=?^`{|}~+-]/
    AUTO_EMAIL_RE = /(?<!#{AUTO_EMAIL_LOCAL_RE})[\w.!#\$%+-]\.?#{AUTO_EMAIL_LOCAL_RE}*@[\w-]+(?:\.[\w-]+)+/
    BRACKETS = { "]" => "[", ")" => "(", "}" => "{" }.freeze

    module_function

    def fragment(html)
      document = Nokogiri::HTML5::Document.new
      document.encoding = "UTF-8"
      document.fragment(html.to_s.strip)
    end

    def to_html(fragment)
      fragment.to_html(save_with: Nokogiri::XML::Node::SaveOptions::AS_HTML)
    end

    # The whole presentation for a text message body (stored Action Text HTML). `attachment_renderer`
    # receives each <action-text-attachment> node and returns its inner HTML (or nil to leave it).
    def presentation(body, attachment_renderer: nil, attachment_text: nil)
      return "" if body.nil?

      html = apply_filters(body, attachment_text)
      rendered = render_attachments(html, attachment_renderer)
      sanitized = sanitizer.sanitize(rendered, tags: ACTION_TEXT_TAGS, attributes: ACTION_TEXT_ATTRIBUTES)
      auto_link(%(<div class="lexxy-content">\n  #{sanitized}\n</div>\n))
    end

    # ContentFilters::TextMessagePresentationFilters: RemoveSoloUnfurledLinkText, SanitizeTags,
    # SanitizeAttributes. Returns HTML.
    def apply_filters(body, attachment_text = nil)
      frag = fragment(body)
      frag = remove_solo_unfurled_link_text(frag, attachment_text)
      frag.css(FILTER_TAGS_SELECTOR).each(&:remove)
      sanitizer.sanitize(to_html(frag), tags: FILTER_TAGS, attributes: FILTER_ATTRIBUTES)
    end

    def render_attachments(html, renderer)
      frag = fragment(html)
      nodes = frag.css(ATTACHMENT_TAG)
      return to_html(frag) if nodes.empty? || renderer.nil?

      nodes.each do |node|
        if node.key?("content")
          content = sanitizer.sanitize(node.remove_attribute("content").to_s, tags: ACTION_TEXT_TAGS, attributes: ACTION_TEXT_ATTRIBUTES)
          node["content"] = content unless content.to_s.strip.empty?
        end
        inner = renderer.call(node)
        node.inner_html = inner if inner
      end
      to_html(frag)
    end

    # ContentFilters::RemoveSoloUnfurledLinkText: when a message is just one unfurled link, drop the
    # link text and keep the embed.
    def remove_solo_unfurled_link_text(frag, attachment_text)
      embeds = frag.css("#{ATTACHMENT_TAG}[content-type='#{OPENGRAPH_CONTENT_TYPE}']")
      return frag unless embeds.size == 1

      href = opengraph_href(embeds.first)
      plain = PlainText.convert(to_html(frag), attachment_text: attachment_text)
      return frag unless href && normalize_tweet_url(href) == normalize_tweet_url(plain)

      if frag.css("div").any?
        frag.css("div").each { |div| div.inner_html = embeds.first.to_s }
      else
        frag.css("p").each { |p| p.remove unless p.at_css(ATTACHMENT_TAG) }
      end
      frag
    end

    def opengraph_href(node)
      if node["filename"].to_s.strip != ""
        node["href"]
      else
        content = fragment(node["content"].to_s)
        content.at_css("a[href]")&.[]("href") || node["href"]
      end
    end

    def normalize_tweet_url(url)
      return url unless url && %w[ x.com twitter.com ].any? { url.strip.include?(it) }
      uri = URI.parse(url)
      uri.host = "twitter.com" if uri.host&.downcase == "x.com"
      uri.query = nil
      uri.to_s
    rescue URI::InvalidURIError
      url
    end

    # rails_autolink's auto_link(text, html: { target: "_blank" }, sanitize_options: ...)
    def auto_link(html)
      return "" if html.strip.empty?

      text = view_sanitizer.sanitize(html, tags: AUTO_LINK_TAGS, attributes: AUTO_LINK_ATTRIBUTES).to_s
      auto_link_email_addresses(auto_link_urls(text))
    end

    def auto_link_urls(text)
      text.gsub(AUTO_LINK_RE) do
        scheme, href = $1, $&
        punctuation = []
        trailing_gt = ""

        if auto_linked?($`, $')
          href
        else
          while href.sub!(/[^\p{Word}\/\-=;]$/, "")
            punctuation.push $&
            if (opening = BRACKETS[punctuation.last]) && href.scan(opening).size > href.scan(punctuation.last).size
              href << punctuation.pop
              break
            end
          end

          trailing_gt = $& if href.sub!(/&gt;$/, "")

          link_text = href
          href = "http://" + href unless scheme
          link_text = view_sanitizer.sanitize(link_text).to_s
          href = view_sanitizer.sanitize(href).to_s
          %(<a target="_blank" href="#{href.gsub('"', "&quot;")}">#{link_text}</a>) + punctuation.reverse.join + trailing_gt
        end
      end
    end

    def auto_link_email_addresses(text)
      text.gsub(AUTO_EMAIL_RE) do
        address = $&
        if auto_linked?($`, $')
          address
        else
          sanitized = view_sanitizer.sanitize(address).to_s
          %(<a target="_blank" href="mailto:#{HTML.h(sanitized)}">#{HTML.h(sanitized)}</a>)
        end
      end
    end

    def auto_linked?(left, right)
      (left =~ AUTO_LINK_CRE[0] && right =~ AUTO_LINK_CRE[1]) ||
        (left.rindex(AUTO_LINK_CRE[2]) && $' !~ AUTO_LINK_CRE[3])
    end

    # Rails::HTML5::SafeListSanitizer keeps one mutable scrubber per instance; one per fiber-free call
    # path is enough here since sanitize runs without yielding.
    def sanitizer
      @sanitizer ||= Rails::HTML5::SafeListSanitizer.new
    end

    def view_sanitizer
      @view_sanitizer ||= Rails::HTML5::SafeListSanitizer.new
    end
  end
end

module Campfire
  # ActionText::PlainTextConversion, with attachments replaced by their plain-text representation
  # (`attachment_text` receives each <action-text-attachment> node).
  module PlainText
    module_function

    def convert(html, attachment_text: nil)
      frag = RichText.fragment(html)
      if attachment_text
        frag.css(RichText::ATTACHMENT_TAG).each { |node| node.replace(Nokogiri::XML::Text.new(attachment_text.call(node).to_s, frag.document)) }
      end
      chomp_all(node_text(frag))
    end

    def node_text(node)
      case node.name
      when "#document-fragment" then children_text(node)
      when "text" then chomp_all(node.text)
      when "script", "style" then ""
      when "h1", "p" then block(node)
      when "ul", "ol"
        text = block(node)
        list_depth(node) > 0 ? "\n#{text}" : text
      when "br" then "\n"
      when "div" then "#{chomp_all(children_text(node))}\n"
      when "figcaption" then "[#{chomp_all(children_text(node))}]"
      when "blockquote"
        text = block(node)
        return "“”" if text.strip.empty?
        text = text.dup
        text.insert(text.rindex(/\S/) + 1, "”")
        text.insert(text.index(/\S/), "“")
        text
      when "li"
        list = node.ancestors.map(&:name).find { it.match?(/^[uo]l$/) }
        bullet = list == "ol" ? "#{node.parent.elements.index(node) + 1}." : "•"
        depth = list_depth(node)
        "#{"  " * (depth - 1) if depth > 1}#{bullet} #{chomp_all(children_text(node))}\n"
      else
        node.element? || node.fragment? ? children_text(node) : (node.text? ? chomp_all(node.text) : "")
      end
    end

    def children_text(node)
      node.children.map { node_text(it) }.join
    end

    def block(node)
      "#{chomp_all(children_text(node))}\n\n"
    end

    def list_depth(node)
      node.ancestors.count { it.respond_to?(:name) && it.name.match?(/^[uo]l$/) }
    end

    def chomp_all(text)
      text.chomp("")
    end
  end
end
