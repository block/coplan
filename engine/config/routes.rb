CoPlan::Engine.routes.draw do
  resources :plans, only: [:index, :show, :edit, :update] do
    patch :publish, on: :member
    patch :archive, on: :member
    patch :unarchive, on: :member
    patch :toggle_checkbox, on: :member
    patch :move_to_folder, on: :member
    get :history, on: :member
    get :edit_content, on: :member
    patch :update_content, on: :member
    post :preview, on: :member
    resources :versions, controller: "plan_versions", only: [:show] do
      get :diff, on: :member
    end
    resources :references, controller: "references", only: [:create, :destroy]
    resources :attachments, controller: "attachments", only: [:create, :destroy]
    resources :comment_threads, only: [:create] do
      member do
        patch :resolve
        patch :accept
        patch :discard
        patch :reopen
      end
      resources :comments, only: [:create, :destroy]
    end
  end

  namespace :settings do
    root "settings#index"
    resources :tokens, only: [:index, :create, :destroy]
    patch "theme", to: "settings#update_theme"
  end

  # Web folder creation (sidebar "New folder" form). Rename/delete go
  # through the API or admin for now.
  resources :folders, only: [:create]

  namespace :api do
    namespace :v1 do
      resources :tags, only: [:index]
      resources :folders, only: [:index, :create, :update, :destroy]
      resources :plans, only: [:index, :show, :create, :update] do
        get :versions, on: :member
        get :comments, on: :member
        get :snapshot, on: :member
        resource :content, only: [:update], controller: "content"
        resource :lease, only: [:create, :update, :destroy], controller: "leases"
        resources :operations, only: [:create]
        resources :sessions, only: [:create, :show], controller: "sessions" do
          post :commit, on: :member
        end
        resources :comments, only: [:create], controller: "comments" do
          post :reply, on: :member
          patch :resolve, on: :member
          patch :discard, on: :member
        end
        # Deletes an individual comment (by comment ID, not thread ID).
        # Distinct from the routes above, which key off thread ID.
        delete "comments/:id/delete", to: "comments#destroy", as: :destroy_comment
        resources :references, only: [:index, :create, :destroy]
        resources :attachments, only: [:index, :create, :destroy]
      end
      resources :references, only: [] do
        get :search, on: :collection
      end
    end
  end

  resources :users, only: [] do
    get :search, on: :collection
  end

  resources :notifications, only: [:index, :show] do
    member do
      patch :mark_read
    end
    collection do
      post :mark_all_read
    end
  end

  get "llms.txt", to: "llms#show", as: :llms_txt
  get "agent-instructions", to: "agent_instructions#show", as: :agent_instructions

  # Service worker — served from a route (not the asset pipeline) so it has a
  # stable URL the browser can update in place. Scope is whatever the engine
  # is mounted at in the host app.
  get "coplan_service_worker.js", to: "service_workers#show", as: :service_worker

  # Web Push subscription management. Endpoint URLs come from the browser's
  # PushManager and uniquely identify a (browser, device, app) tuple per user.
  scope :web_push, module: "web_push", as: :web_push do
    resource :subscription, only: [:create, :destroy], controller: "subscriptions"
    # Turbo-frame target for the per-device list on the Settings page.
    # Reloaded by the settings Stimulus controller after enable/disable so
    # the list reflects the new browser without a full page refresh.
    get "devices", to: "subscriptions#devices", as: :devices
  end

  get "welcome", to: "welcome#show", as: :welcome

  get "search", to: "search#index", as: :search

  root "welcome#show"
end
