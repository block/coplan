ActiveAdmin.register CoPlan::ReviewRequest, as: "ReviewRequest" do
  actions :index, :show
  includes :plan, :reviewer
  filter :plan
  filter :reviewer
  filter :requirement, as: :select, collection: CoPlan::ReviewRequest::REQUIREMENTS
  filter :status, as: :select, collection: CoPlan::ReviewRequest::STATUSES
  filter :requested_at
end
