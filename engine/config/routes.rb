CoPlan::Engine.routes.draw do
  resources :plans, only: [:index, :show, :edit, :update] do
    patch :update_status, on: :member
    patch :toggle_checkbox, on: :member
    get :history, on: :member
    resources :versions, controller: "plan_versions", only: [:show] do
      get :diff, on: :member
    end
    resources :references, controller: "references", only: [:create, :destroy]
    resources :automated_reviews, only: [:create]
    resources :comment_threads, only: [:create] do
      member do
        patch :resolve
        patch :accept
        patch :discard
        patch :reopen
      end
      resources :comments, only: [:create]
    end
  end

  namespace :settings do
    root "settings#index"
    resources :tokens, only: [:index, :create, :destroy]
    patch "theme", to: "settings#update_theme"
  end

  namespace :api do
    namespace :v1 do
      resources :users, only: [] do
        get :search, on: :collection
      end
      resources :tags, only: [:index]
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
        resources :references, only: [:index, :create, :destroy]
      end
      resources :references, only: [] do
        get :search, on: :collection
      end
    end
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

  root "plans#index"
end
