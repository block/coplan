CoPlan::Engine.routes.draw do
  resources :plans, only: [ :index, :show, :edit, :update ] do
    patch :publish, on: :member
    patch :hide, on: :member
    patch :archive, on: :member
    patch :unarchive, on: :member
    patch :toggle_checkbox, on: :member
    patch :move_to_folder, on: :member
    get :history, on: :member
    get :edit_content, on: :member
    patch :update_content, on: :member
    post :preview, on: :member
    resources :versions, controller: "plan_versions", only: [ :show ] do
      get :diff, on: :member
    end
    resources :references, controller: "references", only: [ :create, :destroy ]
    resources :attachments, controller: "attachments", only: [ :create, :destroy ]
    # Cleans up a spoken remark and works out which passage it was about;
    # see DictationsController.
    resources :dictations, only: [ :create ]
    resources :comment_threads, only: [ :create ] do
      member do
        patch :resolve
        patch :accept
        patch :discard
        patch :reopen
      end
      resources :comments, only: [ :create, :destroy ]
    end
  end

  namespace :settings do
    root "settings#index"
    resources :tokens, only: [ :index, :create, :destroy ]
    patch "theme", to: "settings#update_theme"
    patch "voice_hotkey", to: "settings#update_voice_hotkey"
  end

  # Web folder creation (sidebar "New folder" input) and reparenting (drag
  # a folder onto a folder). Rename/delete go through the API or admin for
  # now.
  resources :folders, only: [ :create, :update ]

  # Browsable library URLs — the canonical address of everything in a
  # library, and the reason every other route in this file could stay put:
  #
  #   /l                                 libraries you can see
  #   /l/orders                          a library
  #   /l/orders/liveorder                a folder
  #   /l/orders/liveorder/cart-roadmap   a plan
  #
  # Every prefix is a real page, so trimming a segment walks up the tree.
  # The /l prefix seals the namespace: a handle can never collide with an
  # app route, which makes this a pure addition rather than a migration.
  #
  # `format: false` on the glob, or a plan slug like "pricing-v1.2" would
  # have its tail parsed as a format.
  get "l", to: "libraries#index", as: :browse_root
  get "l/:handle", to: "browse#browse", as: :browse_library
  get "l/:handle/*slug_path", to: "browse#browse", as: :browse, format: false

  # Id-based library browsing, kept so old links resolve. Both forms 301
  # to the browsable paths above. "library" without an id is the
  # signed-in user's own — handy for nav links.
  resources :libraries, only: [ :show ]
  get "library", to: "libraries#mine", as: :my_library

  # Profile pages — the front door to a person's library. :id is a
  # username or user id; usernames may contain dots, so the constraint
  # keeps Rails from peeling ".l" off "hampton.l" as a format.
  get "people/:id", to: "profiles#show", as: :profile, constraints: { id: %r{[^/]+} }

  namespace :api do
    namespace :v1 do
      resources :tags, only: [ :index ]
      # Plan-type catalog (with templates) — agents read this before
      # creating a plan; see the Create Plan section of /agent-instructions.
      resources :plan_types, only: [ :index ]
      resources :folders, only: [ :index, :create, :update, :destroy ]

      # The agent organization API: overview (show), bulk read (contents),
      # bulk write (organize), audit log (events). The bare /library routes
      # are the caller's own library, no id needed.
      resources :libraries, only: [ :index, :show ] do
        member do
          get :contents
          get :events
          post :organize
        end
      end
      get "library", to: "libraries#show", as: :own_library
      get "library/contents", to: "libraries#contents", as: :own_library_contents
      get "library/events", to: "libraries#events", as: :own_library_events
      post "library/organize", to: "libraries#organize", as: :own_library_organize

      resources :plans, only: [ :index, :show, :create, :update ] do
        get :versions, on: :member
        get :locations, on: :member
        get :comments, on: :member
        get :snapshot, on: :member
        resource :content, only: [ :update ], controller: "content"
        resource :lease, only: [ :create, :update, :destroy ], controller: "leases"
        resources :operations, only: [ :create ]
        resources :sessions, only: [ :create, :show ], controller: "sessions" do
          post :commit, on: :member
        end
        resources :comments, only: [ :create ], controller: "comments" do
          post :reply, on: :member
          patch :resolve, on: :member
          patch :discard, on: :member
        end
        # Deletes an individual comment (by comment ID, not thread ID).
        # Distinct from the routes above, which key off thread ID.
        delete "comments/:id/delete", to: "comments#destroy", as: :destroy_comment
        resources :references, only: [ :index, :create, :destroy ]
        resources :attachments, only: [ :index, :create, :destroy ]
      end
      resources :references, only: [] do
        get :search, on: :collection
      end

      # Mint a short-lived session token — the one API call that accepts
      # the host's request auth alone, since it is how an agent gets the
      # Bearer token every other call requires. DELETE revokes whichever
      # token authenticated the request.
      resources :tokens, only: [ :create ]
      delete "tokens/current", to: "tokens#destroy", as: :revoke_current_token
    end
  end

  resources :users, only: [] do
    get :search, on: :collection
  end

  resources :notifications, only: [ :index, :show ] do
    member do
      patch :mark_read
    end
    collection do
      post :mark_all_read
      post :mark_plan_read
    end
  end

  get "llms.txt", to: "llms#show", as: :llms_txt
  get "agent-instructions", to: "agent_instructions#show", as: :agent_instructions
  # Sub-instructions: the library-organizing guide, fetched on demand so the
  # main instructions stay small (agents only spend context when organizing).
  get "agent-instructions/organizing", to: "agent_instructions#organizing", as: :agent_instructions_organizing

  # Service worker — served from a route (not the asset pipeline) so it has a
  # stable URL the browser can update in place. Scope is whatever the engine
  # is mounted at in the host app.
  get "coplan_service_worker.js", to: "service_workers#show", as: :service_worker

  # Web Push subscription management. Endpoint URLs come from the browser's
  # PushManager and uniquely identify a (browser, device, app) tuple per user.
  scope :web_push, module: "web_push", as: :web_push do
    resource :subscription, only: [ :create, :destroy ], controller: "subscriptions"
    # Turbo-frame target for the per-device list on the Settings page.
    # Reloaded by the settings Stimulus controller after enable/disable so
    # the list reflects the new browser without a full page refresh.
    get "devices", to: "subscriptions#devices", as: :devices
  end

  get "home", to: "home#show", as: :home

  get "welcome", to: "welcome#show", as: :welcome

  get "search", to: "search#index", as: :search

  root "welcome#show"
end
