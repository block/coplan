CoPlan::Slack::Engine.routes.draw do
  post "/events", to: "events#create"
end
