require "securerandom"
require "digest"
require "fileutils"

module Campfire
  # Active Storage's disk service and URL formats: blobs live at storage/files/xx/yy/key, and
  # blob, representation and disk URLs carry messages signed by the "ActiveStorage" verifier
  # (HMAC-SHA1, the legacy envelope with `message`, as Rails.application.message_verifier writes).
  module Storage
    module_function

    def root
      File.join(ENV.fetch("STORAGE_PATH", "storage"), "files")
    end

    def path_for(key)
      File.join(root, key[0, 2], key[2, 2], key)
    end

    def verifier(runtime)
      @verifier ||= RailsCompat::MessageVerifier.new(
        RailsCompat::KeyGenerator.new(ENV.fetch("SECRET_KEY_BASE")).generate_key("ActiveStorage"),
        digest: "SHA1", format: :envelope_data, url_safe: false)
    end

    # ActiveStorage::Blob#signed_id: {"_rails":{"data":id,"pur":"blob_id"}}
    def signed_blob_id(runtime, blob_id)
      (@signed_blob_ids ||= {})[blob_id] ||= verifier(runtime).generate(blob_id, purpose: "blob_id")
    end

    def find_signed_blob_id(runtime, signed)
      value = verifier(runtime).verify(signed, purpose: "blob_id")
      Integer(value) rescue nil
    end

    def verify(runtime, signed, purpose)
      verifier(runtime).verify(signed, purpose: purpose)
    end

    def blob_path(runtime, blob, disposition: nil)
      path = "/rails/active_storage/blobs/redirect/#{signed_blob_id(runtime, blob.id)}/#{escape_filename(blob.filename)}"
      disposition ? "#{path}?disposition=#{disposition}" : path
    end

    def variation_key(runtime, transformations)
      verifier(runtime).generate(transformations, purpose: "variation")
    end

    def representation_path(runtime, blob, transformations)
      "/rails/active_storage/representations/redirect/#{signed_blob_id(runtime, blob.id)}/#{variation_key(runtime, transformations)}/#{escape_filename(blob.filename)}"
    end

    # ActiveStorage::Blob::Servable, with Active Storage's default type lists (as the Rust port's
    # crates/storage/src/content_types.rs): types a browser would run as a page are served as
    # binary, and anything not allowed inline is an attachment.
    SERVE_AS_BINARY = %w[ text/html image/svg+xml application/postscript application/x-shockwave-flash text/xml
      application/xml application/xhtml+xml application/mathml+xml text/cache-manifest ].freeze
    ALLOWED_INLINE = %w[ image/webp image/avif image/png image/gif image/jpeg image/tiff image/bmp
      image/vnd.adobe.photoshop image/vnd.microsoft.icon application/pdf ].freeze

    def content_type_for_serving(content_type)
      SERVE_AS_BINARY.include?(content_type) ? "application/octet-stream" : content_type
    end

    def forced_disposition_for_serving(content_type)
      "attachment" if SERVE_AS_BINARY.include?(content_type) || !ALLOWED_INLINE.include?(content_type)
    end

    def disk_path(runtime, key:, filename:, content_type:, disposition:)
      payload = { "key" => key, "disposition" => disposition, "content_type" => content_type, "service_name" => "local" }
      encoded = verifier(runtime).generate(payload, purpose: "blob_key", expires_at: Time.now + 300)
      "/rails/active_storage/disk/#{encoded}/#{escape_filename(filename)}"
    end

    TRADITIONAL_ESCAPED_CHAR = /[^ A-Za-z0-9!\#$+.^_`|~-]/
    RFC_5987_ESCAPED_CHAR = /[^A-Za-z0-9!\#$&+.^_`|~-]/

    # ActionDispatch::Http::ContentDisposition.format (I18n.transliterate turns non-ASCII into "?")
    def content_disposition(disposition, filename)
      ascii = filename.gsub(/[^\x00-\x7F]/, "?")
      %(#{disposition}; filename="#{percent_escape(ascii, TRADITIONAL_ESCAPED_CHAR)}"; filename*=UTF-8''#{percent_escape(filename, RFC_5987_ESCAPED_CHAR)})
    end

    def percent_escape(string, pattern)
      string.gsub(pattern) { |char| char.bytes.map { "%%%02X" % it }.join }
    end

    def escape_filename(filename)
      URI.encode_www_form_component(filename).gsub("+", "%20")
    end

    def generate_key
      Tokens.base36(28)
    end
  end
end
