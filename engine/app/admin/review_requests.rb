ActiveAdmin.register CoPlan::ReviewRequest do
  actions :index, :show
  includes :plan, :reviewer
end
