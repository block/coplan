ActiveAdmin.register CoPlan::ReviewResponse do
  actions :index, :show
  includes :plan_version, :user
end
