require "digest"
require "fileutils"

module Campfire
  # Active Storage uploads for message attachments: the blob row and file, analysis, and the
  # thumb variant (ImageProcessing::Vips resize_to_limit + its sharpen mask), stored as Rails
  # stores variants (a variant record whose `image` attachment is the variant's blob).
  module Uploads
    SHARPEN = [ [ -1, -1, -1 ], [ -1, 32, -1 ], [ -1, -1, -1 ] ].freeze

    module_function

    # config/initializers/vips.rb: only fuzzed loaders, and no OpenSlide.
    def load_vips
      return if defined?(@vips_loaded)
      require "vips"
      Vips.block_untrusted(true)
      Vips.block("VipsForeignLoadOpenslide", true)
      @vips_loaded = true
    end

    def store(ctx, upload)
      tempfile = upload[:tempfile]
      filename = File.basename(upload[:filename].to_s)
      key = Storage.generate_key
      path = Storage.path_for(key)
      content_type, checksum = Campfire.file_io do
        FileUtils.mkdir_p(File.dirname(path))
        FileUtils.cp(tempfile.path, path)
        [ identify(path, filename, upload[:type]), Digest::MD5.file(path).base64digest ]
      end
      now = TimeFormat.now_text

      ctx.db.transaction do |w|
        w.run("INSERT INTO active_storage_blobs (byte_size, checksum, content_type, created_at, filename, key, metadata, service_name) VALUES (?, ?, ?, ?, ?, ?, ?, 'local')",
          File.size(path), checksum, content_type, now, filename, key, '{"identified":true}')
        Blob.new(w.last_insert_row_id, File.size(path), checksum, content_type, now, filename, key, '{"identified":true}', "local")
      end
    end

    def attach(w, blob, record_type, record_id, name, now)
      w.run("INSERT INTO active_storage_attachments (blob_id, created_at, name, record_id, record_type) VALUES (?, ?, ?, ?, ?)",
        blob.id, now, name, record_id, record_type)
    end

    # Message#process_attachment: analyze, then build the thumbnail ahead of the first request.
    def process(ctx, blob)
      analyze(ctx, blob)
      blob = ctx.repo.db.row("SELECT #{Blob.columns} FROM active_storage_blobs WHERE id = ?", blob.id).then { Blob.new(*it) }
      variant_blob(ctx, blob, Attachments.thumb_transformations(blob)) if Attachments.variable?(blob)
    end

    def analyze(ctx, blob)
      load_vips
      metadata = { "identified" => true }
      if blob.image?
        if (image = (Vips::Image.new_from_file(Storage.path_for(blob.key)) rescue nil))
          width, height = image.width, image.height
          width, height = height, width if rotated?(image)
          metadata.merge!("width" => width, "height" => height)
        end
      end
      metadata["analyzed"] = true
      ctx.db.transaction { |w| w.run("UPDATE active_storage_blobs SET metadata = ? WHERE id = ?", JSON.generate(metadata), blob.id) }
    end

    def rotated?(image)
      orientation = image.get("orientation") rescue nil
      orientation.to_i.between?(5, 8)
    end

    # ActiveStorage::VariantWithRecord#processed: the variant's blob, created on first use.
    def variant_blob(ctx, blob, transformations)
      digest = variation_digest(transformations)
      existing = ctx.db.row(<<~SQL, blob.id, digest)
        SELECT #{Blob.columns} FROM active_storage_variant_records
        JOIN active_storage_attachments ON active_storage_attachments.record_type = 'ActiveStorage::VariantRecord'
          AND active_storage_attachments.record_id = active_storage_variant_records.id AND active_storage_attachments.name = 'image'
        JOIN active_storage_blobs ON active_storage_blobs.id = active_storage_attachments.blob_id
        WHERE active_storage_variant_records.blob_id = ? AND active_storage_variant_records.variation_digest = ? LIMIT 1
      SQL
      return Blob.new(*existing) if existing

      format = transformations["format"].to_s
      key = Storage.generate_key
      path = Storage.path_for(key)
      FileUtils.mkdir_p(File.dirname(path))
      width, height = transform(Storage.path_for(blob.key), path, transformations)
      filename = "#{File.basename(blob.filename, ".*")}.#{format}"
      content_type = { "jpg" => "image/jpeg", "jpeg" => "image/jpeg", "png" => "image/png", "webp" => "image/webp", "gif" => "image/gif" }[format] || blob.content_type
      metadata = JSON.generate({ "identified" => true, "width" => width, "height" => height, "analyzed" => true })
      now = TimeFormat.now_text
      checksum = Campfire.file_io { Digest::MD5.file(path).base64digest }

      ctx.db.transaction do |w|
        w.run("INSERT INTO active_storage_variant_records (blob_id, variation_digest) VALUES (?, ?)", blob.id, digest)
        record_id = w.last_insert_row_id
        w.run("INSERT INTO active_storage_blobs (byte_size, checksum, content_type, created_at, filename, key, metadata, service_name) VALUES (?, ?, ?, ?, ?, ?, ?, 'local')",
          File.size(path), checksum, content_type, now, filename, key, metadata)
        variant = Blob.new(w.last_insert_row_id, File.size(path), checksum, content_type, now, filename, key, metadata, "local")
        attach(w, variant, "ActiveStorage::VariantRecord", record_id, "image", now)
        variant
      end
    end

    def transform(source, destination, transformations)
      load_vips
      width, height = transformations["resize_to_limit"]
      image = Vips::Image.new_from_file(source).autorot
      image = image.thumbnail_image(width, height: height, size: :down, no_rotate: true)
      image = image.conv(Vips::Image.new_from_array(SHARPEN, 24), precision: :integer)
      image.write_to_file("#{destination}.#{transformations["format"]}")
      File.rename("#{destination}.#{transformations["format"]}", destination)
      [ image.width, image.height ]
    end

    # ActiveStorage::Variation#digest: SHA1 of the Marshal-dumped, symbol-keyed transformations.
    def variation_digest(transformations)
      Digest::SHA1.base64digest(Marshal.dump(transformations.transform_keys(&:to_sym)))
    end

    # Marcel's identification, reduced to the formats that matter here: trust the declared type
    # unless the bytes say otherwise.
    def identify(path, filename, declared)
      magic = File.binread(path, 12).to_s.b
      case
      when magic.start_with?("\xFF\xD8\xFF".b) then "image/jpeg"
      when magic.start_with?("\x89PNG".b) then "image/png"
      when magic.start_with?("GIF8".b) then "image/gif"
      when magic[0, 4] == "RIFF".b && magic[8, 4] == "WEBP".b then "image/webp"
      when magic.start_with?("BM".b) then "image/bmp"
      else declared.to_s.empty? ? "application/octet-stream" : declared
      end
    end
  end
end
