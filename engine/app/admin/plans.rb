ActiveAdmin.register CoPlan::Plan, as: "Plan" do
  permit_params :title, :visibility, :archived_at

  filter :title
  filter :visibility, as: :select, collection: CoPlan::Plan::VISIBILITIES
  filter :archived_at
  filter :plan_type, as: :select
  filter :created_at
  filter :updated_at

  index do
    selectable_column
    id_column
    column :title
    column :visibility
    column("Archived") { |plan| plan.archived? }
    column :current_revision
    column :created_by_user
    column :updated_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :title
      row :visibility
      row :archived_at
      row :current_revision
      row :created_by_user
      row(:tags) { |plan| plan.tag_names.join(", ") }
      row :metadata
      row :created_at
      row :updated_at
    end
  end
end
