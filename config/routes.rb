# The reference's routes (config/routes.rb in once-campfire). Rage matches static segments before
# parameters, so the order here doesn't matter.
Rage.routes.draw do
  get "/up", to: "health#show"
  %w[ /404.html /422.html /500.html /502.html /robots.txt ].each { get it, to: "public_files#show" }

  # Sessions, first run, joining, transfers
  get "/session/new", to: "sessions#new"
  post "/session", to: "sessions#create"
  delete "/session", to: "sessions#destroy"
  get "/first_run", to: "first_runs#show"
  post "/first_run", to: "first_runs#create"
  get "/join/:join_code", to: "joins#new"
  post "/join/:join_code", to: "joins#create"
  get "/session/transfers/:id", to: "transfers#show"
  put "/session/transfers/:id", to: "transfers#update"

  # Rooms
  get "/", to: "rooms#root"
  get "/rooms", to: "rooms#index"
  get "/rooms/:room_id", to: "rooms#show"
  get "/rooms/:room_id/@:message_id", to: "rooms#show"
  delete "/rooms/:id", to: "rooms#destroy"
  delete "/rooms/directs/:id", to: "rooms#destroy"
  get "/rooms/:room_id/refresh", to: "rooms#refresh"
  get "/rooms/:room_id/involvement", to: "involvements#show"
  put "/rooms/:room_id/involvement", to: "involvements#update"

  %w[ opens closeds ].each do |kind|
    get "/rooms/#{kind}/new", to: "room_settings#new", defaults: { kind: }
    get "/rooms/#{kind}/:id/edit", to: "room_settings#edit", defaults: { kind: }
    get "/rooms/#{kind}/:id", to: "room_settings#show", defaults: { kind: }
    post "/rooms/#{kind}", to: "room_settings#create", defaults: { kind: }
    patch "/rooms/#{kind}/:id", to: "room_settings#update", defaults: { kind: }
  end

  get "/rooms/directs/new", to: "directs#new"
  post "/rooms/directs", to: "directs#create"
  get "/rooms/directs/:id/edit", to: "directs#edit"
  get "/rooms/directs/:id", to: "directs#show"

  # Messages
  get "/rooms/:room_id/messages", to: "messages#index"
  post "/rooms/:room_id/messages", to: "messages#create"
  get "/rooms/:room_id/messages/:id", to: "messages#show"
  get "/rooms/:room_id/messages/:id/edit", to: "messages#edit"
  patch "/rooms/:room_id/messages/:id", to: "messages#update"
  delete "/rooms/:room_id/messages/:id", to: "messages#destroy"

  get "/messages/:message_id/boosts", to: "boosts#index"
  get "/messages/:message_id/boosts/new", to: "boosts#new"
  post "/messages/:message_id/boosts", to: "boosts#create"
  delete "/messages/:message_id/boosts/:id", to: "boosts#destroy"

  # The bot API: /rooms/:room_id/:bot_key/messages
  %w[ messages messages.json ].each do |collection|
    get "/rooms/:room_id/:bot_key/#{collection}", to: "bot_messages#index"
    post "/rooms/:room_id/:bot_key/#{collection}", to: "bot_messages#create"
  end
  # Rage has no suffix after a parameter, so the actions take "123.json" too.
  put "/rooms/:room_id/:bot_key/messages/:id", to: "bot_messages#update"
  patch "/rooms/:room_id/:bot_key/messages/:id", to: "bot_messages#update"
  delete "/rooms/:room_id/:bot_key/messages/:id", to: "bot_messages#destroy"
  post "/rooms/:room_id/:bot_key/messages/:message_id/boosts", to: "bot_messages#create_boost"
  post "/rooms/:room_id/:bot_key/messages/:message_id/boosts.json", to: "bot_messages#create_boost"
  delete "/rooms/:room_id/:bot_key/messages/:message_id/boosts/:id", to: "bot_messages#destroy_boost"

  # Account
  get "/account/edit", to: "accounts#edit"
  patch "/account", to: "accounts#update"
  put "/account", to: "accounts#update"
  get "/account/users", to: "account_users#index"
  get "/account/users.turbo_stream", to: "account_users#index"
  patch "/account/users/:id", to: "account_users#update"
  delete "/account/users/:id", to: "account_users#destroy"
  post "/account/join_code", to: "accounts#reset_join_code"
  get "/account/custom_styles/edit", to: "custom_styles#edit"
  patch "/account/custom_styles", to: "custom_styles#update"
  get "/account/logo", to: "account_logos#show"
  delete "/account/logo", to: "account_logos#destroy"

  get "/account/bots", to: "bots#index"
  get "/account/bots/new", to: "bots#new"
  get "/account/bots/:id/edit", to: "bots#edit"
  post "/account/bots", to: "bots#create"
  patch "/account/bots/:id", to: "bots#update"
  put "/account/bots/:id/key", to: "bots#reset_key"
  delete "/account/bots/:id", to: "bots#destroy"

  # Users
  get "/users/:id", to: "users#show"
  get "/users/me/profile", to: "profiles#show"
  patch "/users/me/profile", to: "profiles#update"
  delete "/users/:id/avatar", to: "profiles#remove_avatar"
  post "/users/:id/ban", to: "bans#create"
  delete "/users/:id/ban", to: "bans#destroy"
  get "/users/:id/sidebar", to: "sidebars#show"
  get "/users/:token/avatar", to: "avatars#show"

  get "/users/me/push_subscriptions", to: "push_subscriptions#index"
  post "/users/me/push_subscriptions", to: "push_subscriptions#create"
  delete "/users/me/push_subscriptions/:id", to: "push_subscriptions#destroy"
  post "/users/me/push_subscriptions/:id/test_notifications", to: "push_subscriptions#test"

  # Searches, autocomplete, link unfurling
  get "/searches", to: "searches#index"
  post "/searches", to: "searches#create"
  delete "/searches/clear", to: "searches#clear"
  get "/autocompletable/users", to: "autocompletes#index"
  get "/autocompletable/users.json", to: "autocompletes#index", defaults: { format: "json" }
  post "/unfurl_link", to: "unfurls#create"

  # PWA, QR codes, Active Storage
  get "/webmanifest", to: "pwa#manifest"
  get "/webmanifest.json", to: "pwa#manifest"
  get "/service-worker", to: "pwa#service_worker"
  get "/service-worker.js", to: "pwa#service_worker"
  get "/qr_code/:id", to: "qr_codes#show"
  get "/rails/active_storage/blobs/redirect/:signed_id/*", to: "active_storage#blob"
  get "/rails/active_storage/representations/redirect/:signed_blob_id/:variation_key/*", to: "active_storage#representation"
  get "/rails/active_storage/disk/:encoded_key/*", to: "active_storage#disk"

  mount Campfire::CableGate.new(Rage.cable.application), at: "/cable"

  # Everything else: the public 404 page.
  match "/*", to: "errors#not_found", via: :all
end
