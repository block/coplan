ActiveAdmin.register Coplan::ReviewResponse, as: "ReviewResponse" do
  actions :index, :show
  includes :plan_version, :user
  filter :user
  filter :decision, as: :select, collection: Coplan::ReviewResponse::DECISIONS
  filter :actor_type, as: :select, collection: Coplan::ReviewResponse::ACTOR_TYPES
  filter :created_at
end
