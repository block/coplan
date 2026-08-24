CoPlan::Engine.routes.draw do
  # --- The shape of this file ----------------------------------------
  #
  # People are the root namespace. A handle is a top-level segment, so a
  # document's address reads like the person whose library it's in:
  #
  #   /sam                               Sam, and Sam's library
  #   /sam/liveorder                     a folder
  #   /sam/liveorder/cart-state-machine  a document
  #
  # Every prefix is a real page, so trimming a segment walks up the tree.
  #
  # Everything that isn't a place lives under `_`: settings, search, the
  # id-based mutation endpoints, and whatever gets added next. That single
  # character is the whole reservation — a handle can never *be* `_`,
  # because slug rules strip non-alphanumerics (CoPlan::Slug), so the split
  # is structural rather than a list someone has to remember to update.
  # `_` is reserved inside a library too (/sam/_/…), by the same mechanism,
  # so library-scoped pages have somewhere to go that can't collide with a
  # folder name.
  #
  # The legacy block near the bottom is the one fixed list, frozen at the
  # paths that shipped before this. It can shrink; it never has to grow.
  #
  # Order matters: the `:handle` routes at the very bottom are a catchall,
  # so everything else has to be declared above them.

  # Handles are ASCII slugs, so they never contain a dot. That's what keeps
  # file-like root paths (llms.txt, the service worker) out of the catchall
  # without needing to enumerate them.
  handle = /[a-z0-9][a-z0-9-]*/

  # A 301 that survives being mounted somewhere other than "/".
  legacy = ->(to) { redirect(status: 301) { |_params, req| "#{req.script_name}#{to}" } }

  # --- App machinery -------------------------------------------------
  #
  # Path-only scope: helper names stay unprefixed, so `settings_path`,
  # `publish_plan_path` and the rest read the same at every call site.
  scope "_" do
    # Id-based mutations, and nothing else. A document's pages all hang off
    # its readable address (see the browse routes at the bottom); what's
    # left here is the machinery behind the buttons on them, which is
    # keyed by id because a button doesn't need a readable URL.
    #
    # `:update` is what keeps the `plan_path` helper — the PATCH target for
    # the title-and-tags form.
    resources :plans, only: [ :update ] do
      patch :publish, on: :member
      patch :hide, on: :member
      patch :archive, on: :member
      patch :unarchive, on: :member
      patch :toggle_checkbox, on: :member
      patch :move_to_folder, on: :member
      patch :update_content, on: :member
      post :preview, on: :member
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

    # Every library you can see. Id-based library links land here too, and
    # 301 onward to the handle form.
    get "libraries", to: "libraries#index", as: :browse_root
    resources :libraries, only: [ :show ]
    get "library", to: "libraries#mine", as: :my_library

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
  end

  # --- Root-level by necessity ---------------------------------------

  # The agent API is an external contract with published paths; moving it
  # under `_` would break every caller for no gain.
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

  # The published entry point for agents — it's in every API response, in
  # llms.txt, and in whatever config people have already pasted it into.
  # Same argument as the API above: an external contract stays where it was.
  get "agent-instructions", to: "agent_instructions#show", as: :agent_instructions
  # Sub-instructions: the library-organizing guide, fetched on demand so the
  # main instructions stay small (agents only spend context when organizing).
  get "agent-instructions/organizing", to: "agent_instructions#organizing", as: :agent_instructions_organizing

  # Convention puts this at the root, like robots.txt.
  get "llms.txt", to: "llms#show", as: :llms_txt

  # Service worker — served from a route (not the asset pipeline) so it has
  # a stable URL the browser can update in place. This one *has* to stay at
  # the root: a worker's scope is the directory it's served from, and push
  # notifications need to focus and navigate any tab, not just /_/*.
  get "coplan_service_worker.js", to: "service_workers#show", as: :service_worker

  # --- Legacy paths --------------------------------------------------
  #
  # The addresses that shipped before people became the root namespace.
  # This is the whole reserved list, and it's frozen: anything new goes
  # under `_`, which costs no handle. The price is that nobody can have
  # the handle "settings" or "plans", which seems survivable.
  # Most of these reuse the controllers they always pointed at, because
  # those already 301 onward — a document at /plans/<uuid> converges on its
  # readable address whether you arrived by the old path or the new one.
  scope as: :legacy do
    # Your workspace was /plans. It's your library now.
    get "plans", to: "libraries#mine"
    get "library", to: "libraries#mine"
    # PlansController#show 301s onto the readable address — every document
    # has one, so this always converges.
    get "plans/:id", to: "plans#show", as: :plan
    # A person's page and their library are the same page now. :id is a
    # username or a user id; usernames may contain dots, so the constraint
    # keeps Rails from peeling ".l" off "hampton.l" as a format.
    get "people/:id", to: "profiles#show", as: :person, constraints: { id: %r{[^/]+} }
    # LibrariesController#show 301s onward, ?folder=<id> and all.
    get "libraries/:id", to: "libraries#show", as: :library_by_id
    get "libraries", to: legacy.call("/_/libraries"), as: :libraries

    get "settings", to: legacy.call("/_/settings"), as: :settings
    get "settings/*rest", to: redirect(status: 301) { |p, r| "#{r.script_name}/_/settings/#{p[:rest]}" }, as: :settings_page
    get "search", to: legacy.call("/_/search"), as: :search
    get "notifications", to: legacy.call("/_/notifications"), as: :notifications
    get "notifications/*rest", to: redirect(status: 301) { |p, r| "#{r.script_name}/_/notifications/#{p[:rest]}" }, as: :notification_page
    get "home", to: legacy.call("/_/home"), as: :home
    get "welcome", to: legacy.call("/_/welcome"), as: :welcome
  end

  root "welcome#show"

  # --- People, and everything in their libraries ----------------------
  #
  # The catchall. `format: false` on the globs, or a document slug like
  # "pricing-v1.2" would have its tail parsed as a format.
  #
  # `/:handle/_/…` needs no route of its own: a folder can never be named
  # `_` (CoPlan::Slug strips it), so the segment resolves to nothing and
  # 404s. That's the reservation — library-scoped pages can be declared
  # above this line whenever we have one, and nothing a user creates can
  # ever be sitting there already.

  # A document's own pages hang off its address, so trimming the tail
  # walks back to the document — the same property every other prefix in
  # this scheme has. They're unambiguous by construction: a document has
  # no children, so a segment following one can only name an action.
  #
  # All four land on `browse#browse`, which resolves the path once and
  # then dispatches on `page`. When the tail turns out *not* to hang off a
  # document — `/sam/notes/history`, where "notes" is a folder — it gets
  # put back together and resolved as a place, so a plan someone titled
  # "History" keeps its address.
  #
  # Versions are addressed by revision, not id: it's the number already on
  # screen in the history list, and it nests under the page that lists it.
  get ":handle/*slug_path/edit", to: "browse#browse", as: :browse_edit,
    defaults: { page: "edit" }, format: false, constraints: { handle: handle }
  get ":handle/*slug_path/history", to: "browse#browse", as: :browse_history,
    defaults: { page: "history" }, format: false, constraints: { handle: handle }
  get ":handle/*slug_path/history/:revision", to: "browse#browse", as: :browse_version,
    defaults: { page: "version" }, format: false,
    constraints: { handle: handle, revision: /\d+/ }
  get ":handle/*slug_path/history/:revision/diff", to: "browse#browse", as: :browse_version_diff,
    defaults: { page: "version_diff" }, format: false,
    constraints: { handle: handle, revision: /\d+/ }

  get ":handle", to: "browse#browse", as: :browse_library, constraints: { handle: handle }
  get ":handle/*slug_path", to: "browse#browse", as: :browse, format: false, constraints: { handle: handle }
end
