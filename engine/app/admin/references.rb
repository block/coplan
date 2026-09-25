ActiveAdmin.register CoPlan::Reference, as: "Reference" do
  permit_params :plan_id, :key, :url, :title, :reference_type, :source, :target_plan_id

  index do
    selectable_column
    id_column
    column :plan
    column :key
    column :url
    column :title
    column :reference_type
    column :source
    column :target_plan_id
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :plan
      row :key
      row :url
      row :title
      row :reference_type
      row :source
      row :target_plan_id
      row :created_at
      row :updated_at
    end
  end
end
