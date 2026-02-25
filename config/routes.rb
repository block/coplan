Rails.application.routes.draw do
  ActiveAdmin.routes(self)
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  get  "sign_in", to: "sessions#new"
  post "sign_in", to: "sessions#create"
  delete "sign_out", to: "sessions#destroy"

  resources :plans, only: [:index, :show, :edit, :update] do
    patch :update_status, on: :member
    resources :versions, controller: "plan_versions", only: [:index, :show]
    resources :automated_reviews, only: [:create]
    resources :comment_threads, only: [:create] do
      member do
        patch :resolve
        patch :accept
        patch :dismiss
        patch :reopen
      end
      resources :comments, only: [:create]
    end
  end

  namespace :settings do
    resources :tokens, only: [:index, :create, :destroy]
  end

  namespace :api do
    namespace :v1 do
      resources :plans, only: [:index, :show, :create, :update] do
        get :versions, on: :member
        get :comments, on: :member
        resource :lease, only: [:create, :update, :destroy], controller: "leases"
        resources :operations, only: [:create]
        resources :comments, only: [:create], controller: "comments" do
          post :reply, on: :member
          patch :resolve, on: :member
          patch :dismiss, on: :member
        end
      end
    end
  end

  root "dashboard#show"
end
