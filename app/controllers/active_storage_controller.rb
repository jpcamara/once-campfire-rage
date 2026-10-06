class ActiveStorageController < ApplicationController
  action :blob do
    blob = signed_blob!(params["signed_id"])
    redirect_to_disk(blob, params["disposition"])
  end

  action :representation do
    blob = signed_blob!(params["signed_blob_id"])
    transformations = Storage.verify(runtime, params["variation_key"], "variation") or active_storage_not_found
    # ActiveStorage::Preview: a video's representation is a variant of its stored preview image.
    if blob.video?
      row = db.row(<<~SQL, blob.id) or active_storage_not_found
        SELECT #{Blob.columns} FROM active_storage_attachments JOIN active_storage_blobs ON active_storage_blobs.id = active_storage_attachments.blob_id
        WHERE active_storage_attachments.record_type = 'ActiveStorage::Blob' AND active_storage_attachments.record_id = ? AND active_storage_attachments.name = 'preview_image' LIMIT 1
      SQL
      blob = Blob.new(*row)
    end
    variant = Uploads.variant_blob(Context.new(runtime), blob, transformations)
    redirect_to_disk(variant, params["disposition"])
  end

  action :disk do
    without_version_headers
    key = Storage.verify(runtime, params["encoded_key"], "blob_key") or active_storage_not_found
    path = Storage.path_for(key["key"].to_s)
    active_storage_not_found unless File.file?(path)
    headers "cache-control" => "max-age=3600, public", "content-disposition" => key["disposition"].to_s
    send_file path, type: key["content_type"] || "application/octet-stream", disposition: nil
  end
end
