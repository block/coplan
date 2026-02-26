ActiveAdmin.register CoPlan::Plan, as: "Plan" do
  permit_params :title, :status

  index do
    selectable_column
    id_column
    column :title
    column :status
    column :current_revision
    column :created_by_user
    column :updated_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :title
      row :status
      row :current_revision
      row :created_by_user
      row :tags
      row :metadata
      row :created_at
      row :updated_at
    end
  end
end
