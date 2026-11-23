ActiveAdmin.register Coplan::ReviewRequest, as: "ReviewRequest" do
  actions :index, :show
  includes :plan, :reviewer
  filter :plan
  filter :reviewer
  filter :requirement, as: :select, collection: Coplan::ReviewRequest::REQUIREMENTS
  filter :status, as: :select, collection: Coplan::ReviewRequest::STATUSES
  filter :requested_at
end
