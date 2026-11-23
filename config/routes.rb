Rails.application.routes.draw do
  get "/admin", to: redirect("/_/admin")
  get "/admin/*path", to: redirect("/_/admin/%{path}")
  ActiveAdmin.routes(self)

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  get  "sign_in", to: "sessions#new"
  post "sign_in", to: "sessions#create"
  delete "sign_out", to: "sessions#destroy"

  mount Coplan::Slack::Engine => "/integrations/slack", as: :coplan_slack
  mount Coplan::Engine => "/", as: :coplan
end
