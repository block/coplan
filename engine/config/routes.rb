CoPlan::Engine.routes.draw do
  resources :plans, only: [:index, :show, :edit, :update] do
    patch :update_status, on: :member
    resources :versions, controller: "plan_versions", only: [:index, :show]
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
  end

  namespace :api do
    namespace :v1 do
      resources :users, only: [] do
        get :search, on: :collection
      end
      resources :plans, only: [:index, :show, :create, :update] do
        get :versions, on: :member
        get :comments, on: :member
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
