class SidebarsController < ApplicationController
  # Finished sidebars, kept until the database changes, as the Elixir port's sidebar.ex keeps its
  # HTML until one of the tables it reads is written. The key is everything else it's rendered
  # from: the read cache's generation (any write), the user, and the request's host, user agent,
  # frame and Accept. A sidebar with a flash isn't kept.
  KEPT = {}
  KEPT_LIMIT = 1024
  Kept = Data.define(:body, :digest)

  action :show do
    require_authentication!
    html_headers
    key = [ db.generation, current_user, base_url, request.user_agent, env["HTTP_TURBO_FRAME"], env["HTTP_ACCEPT"] ]
    if flash_now.empty? && (kept = KEPT.delete(key))
      KEPT[key] = kept
    else
      body = render_sidebar
      return body unless flash_now.empty?
      kept = KEPT[key] = Kept.new(body.freeze, Digest::MD5.hexdigest(body))
      KEPT.delete(KEPT.first[0]) while KEPT.size > KEPT_LIMIT
    end
    # What the ETag middleware would set, so it doesn't hash the body again.
    headers "etag" => %(W/"#{kept.digest}")
    env[ETag::BODY_DIGEST] = kept.digest
    kept.body
  end
end
