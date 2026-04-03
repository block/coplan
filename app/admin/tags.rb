ActiveAdmin.register CoPlan::Tag, as: "Tag" do
  permit_params :name

  index do
    selectable_column
    id_column
    column :name
    column :plans_count
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :name
      row :plans_count
      row :created_at
      row :updated_at
    end

    panel "Plans" do
      table_for resource.plans.order(updated_at: :desc) do
        column :id
        column :title
        column :status
        column :updated_at
      end
    end
  end
end
