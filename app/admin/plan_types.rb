ActiveAdmin.register CoPlan::PlanType, as: "PlanType" do
  permit_params :name, :description, :template_content

  index do
    selectable_column
    id_column
    column :name
    column :description
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :name
      row :description
      row :default_tags
      row :template_content
      row :metadata
      row :created_at
      row :updated_at
    end
  end
end
