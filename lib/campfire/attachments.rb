module Campfire
  THUMBNAIL_MAX_WIDTH = 1200
  THUMBNAIL_MAX_HEIGHT = 800
  THUMB_TRANSFORMATIONS = { "resize_to_limit" => [ THUMBNAIL_MAX_WIDTH, THUMBNAIL_MAX_HEIGHT ] }.freeze

  # Message attachments (Messages::AttachmentPresentation) and the attachments embedded in rich
  # text bodies (mentions, unfurled links).
  module Attachments
    # ActiveStorage.variable_content_types after config/initializers/vips.rb removes bmp, ico and psd
    VARIABLE_TYPES = %w[ image/png image/gif image/jpeg image/tiff image/webp image/avif image/heic image/heif ].freeze
    OPENGRAPH_CONTENT_TYPE = "application/vnd.actiontext.opengraph-embed"
    TWITTER_AVATAR_URL_PREFIX = "https://pbs.twimg.com/profile_images"

    module_function

    def presentation(ctx, blob)
      runtime = ctx.runtime
      if variable?(blob) || blob.video?
        width, height = preview_dimensions(blob)
        if blob.video?
          poster = Storage.representation_path(runtime, blob, { "format" => "webp", "resize_to_limit" => [ THUMBNAIL_MAX_WIDTH, THUMBNAIL_MAX_HEIGHT ] })
          constrained(width, height, %(<video src="#{blob_path(runtime, blob)}" poster="#{poster}" controls="controls" preload="none" width="100%" height="100%" class="message__attachment"></video>))
        else
          thumb = Storage.representation_path(runtime, blob, thumb_transformations(blob))
          download = blob_path(runtime, blob, "attachment")
          img = %(<img width="#{width}" height="#{height}" class="message__attachment" loading="lazy" src="#{thumb}" />)
          link = %(<a class="flex" data-lightbox-target="image" data-action="lightbox#open" data-lightbox-url-value="#{download}" href="#{blob_path(runtime, blob)}">#{img}</a>)
          constrained(width, height, link)
        end
      else
        download = blob_path(runtime, blob, "attachment")
        name = HTML.h(blob.filename)
        %(<div class="flex-inline align-center gap-half"><img class="colorize--black" aria-hidden="true" src="#{Assets.path("common-file-text.svg")}" width="22" height="22" /><span>#{name}</span><a class="btn message__action-btn hide-in-ios-pwa" style="--width: auto;" href="#{download}"><img aria-hidden="true" src="#{Assets.path("download.svg")}" width="20" height="20" /><span class="for-screen-reader">Download #{name}</span></a><button class="btn message__action-btn" style="--width: auto;" data-controller="web-share" data-action="web-share#share" data-web-share-files-value="#{download}"><img aria-hidden="true" src="#{Assets.path("share.svg")}" width="20" height="20" /><span class="for-screen-reader">Share #{name}</span></button></div>)
      end
    end

    def variable?(blob)
      VARIABLE_TYPES.include?(blob.content_type)
    end

    # The thumb variant keeps the source format; Active Storage records it in the variation.
    def thumb_transformations(blob)
      { "format" => File.extname(blob.filename.to_s).delete_prefix(".").downcase.then { it.empty? ? "png" : it } }.merge(THUMB_TRANSFORMATIONS)
    end

    def blob_path(runtime, blob, disposition = nil)
      Storage.blob_path(runtime, blob, disposition: disposition)
    end

    def constrained(width, height, inner)
      if width && height
        %(<div class="max-inline-size center flex overflow-clip" style="width: #{width / 2}px; aspect-ratio: #{width / height.to_f};">#{inner}</div>)
      else
        %(<div class="max-inline-size center overflow-clip">#{inner}</div>)
      end
    end

    def preview_dimensions(blob)
      metadata = JSON.parse(blob.metadata.to_s) rescue {}
      width, height = metadata["width"], metadata["height"]
      if width.nil? || height.nil?
        [ nil, nil ]
      elsif width <= THUMBNAIL_MAX_WIDTH && height <= THUMBNAIL_MAX_HEIGHT
        [ width, height ]
      else
        scale = [ THUMBNAIL_MAX_WIDTH.to_f / width, THUMBNAIL_MAX_HEIGHT.to_f / height ].min
        [ width * scale, height * scale ]
      end
    end

    # ---- Attachments inside rich text (lib/rails_ext/action_text_attachables.rb's lookup order)

    def attachable(ctx, node)
      if (embed = opengraph_embed(ctx, node))
        [ :opengraph, embed ]
      elsif (user_id = GlobalIds.user_id_from_sgid(node["sgid"])) && (user = ctx.repo.user(user_id))
        [ :mention, user ]
      elsif node["content-type"].to_s.match?(%r{\Atext/html}) && node["content"].to_s.strip != ""
        [ :content, node["content"] ]
      else
        [ :missing, nil ]
      end
    end

    def content_type(ctx, node)
      kind, _ = attachable(ctx, node)
      case kind
      when :opengraph then OPENGRAPH_CONTENT_TYPE
      when :mention then "application/vnd.campfire.mention"
      else node["content-type"]
      end
    end

    # The partial each attachment renders into the node.
    def render(ctx, node, editor: false)
      kind, value = attachable(ctx, node)
      case kind
      when :opengraph then render_opengraph(value)
      when :mention
        sgid = ctx.runtime.secrets.attachable_sgid("User", value.id)
        %(<span class="mention" sgid="#{sgid}">#{ctx.build_view.avatar_tag(value)} #{HTML.h(value.name)}</span>)
      when :content then %(<figure class="attachment attachment--content">\n  #{value}\n</figure>)
      else "☒"
      end
    end

    def plain_text(ctx, node)
      kind, value = attachable(ctx, node)
      case kind
      when :opengraph then ""
      when :mention then "@#{value.name}"
      when :content then PlainText.convert(value)
      else "☒"
      end
    end

    # ActionText::Attachment::OpengraphEmbed.from_node
    def opengraph_embed(ctx, node)
      return nil unless node["content-type"].to_s.include?(OPENGRAPH_CONTENT_TYPE)
      host = ctx.respond_to?(:request) ? ctx.request.host : nil
      if node["filename"].to_s.strip != ""
        { href: web_url(node["href"], host), url: web_url(node["url"], host), filename: node["filename"], description: node["caption"] }
      else
        fragment = Nokogiri::HTML.fragment(node["content"].to_s)
        title = fragment.at_css(".og-embed__title")
        link = title&.at_css("a")
        { href: web_url(link&.[]("href"), host), url: web_url(fragment.at_css(".og-embed__image img")&.[]("src"), host),
          filename: (link || title)&.text&.strip, description: fragment.at_css(".og-embed__description")&.text&.strip }
      end
    end

    def web_url(value, request_host)
      return nil if value.to_s.strip.empty?
      parsed = URI.parse(value)
      value if parsed.is_a?(URI::HTTP) && elsewhere?(parsed.host, request_host)
    rescue URI::InvalidURIError
      nil
    end

    def elsewhere?(host, request_host)
      return false unless host && !host.include?("%") && host.include?(".") && host.split(".").last.then { it.match?(/[a-z]/i) && !it.match?(/\A0x/i) }
      host.downcase.delete_suffix(".") != request_host.to_s.downcase.delete_suffix(".")
    end

    def render_opengraph(embed)
      title = truncate(embed[:filename].to_s, 280)
      title_html = embed[:href].to_s.strip.empty? ? HTML.h(title) : %(<a rel="noreferrer" target="_blank" href="#{HTML.h(embed[:href])}">#{HTML.h(title)}</a>)
      image = embed[:url] ? %(\n        <div class="og-embed__image">\n          <img src="#{HTML.h(embed[:url])}" class="image center" alt="" />\n        </div>) : ""
      avatar = embed[:url].to_s.start_with?(TWITTER_AVATAR_URL_PREFIX) ? "og-embed--twitter-avatar" : ""
      <<~HTML.chomp
        <figure class="attachment attachment--content attachment--og">
          <actiontext-opengraph-embed>
            <div class="og-embed gap #{avatar}">
              <div class="og-embed__content">
                <div class="og-embed__title">
                  #{title_html}
                </div>
                <div class="og-embed__description">#{HTML.h(truncate(embed[:description].to_s, 560))}</div>
              </div>#{image}
            </div>
          </actiontext-opengraph-embed>
        </figure>
      HTML
    end

    # String#truncate(length, omission: "…")
    def truncate(text, length)
      text.size > length ? "#{text[0, length - 1]}…" : text
    end

    # ActionText::Attachment.fragment_by_canonicalizing_attachments: attachments are stored empty.
    def canonicalize(fragment)
      fragment.css(RichText::ATTACHMENT_TAG).each { it.inner_html = "" }
      fragment
    end
  end

  module Sounds
    module_function

    def presentation(sound)
      inner = %(<button class="btn btn--plain" data-action="sound#play">🔊</button>) +
        (sound.image ? %(<img width="#{sound.image.width}" height="#{sound.image.height}" class="align--middle" src="#{Assets.path(sound.image.asset_path)}" />) : HTML.h(sound.text))
      %(<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="#{Assets.path(sound.asset_path)}">#{inner}</div>)
    end
  end
end
