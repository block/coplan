ActiveAdmin.register CoPlan::User, as: "User" do
  permit_params :name, :email, :admin, :avatar_url, :title, :team

  index do
    selectable_column
    id_column
    column :name
    column :email
    column :title
    column :team
    column :admin
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :external_id
      row :name
      row :email
      row :avatar_url
      row :title
      row :team
      row :admin
      row :created_at
      row :updated_at
    end
  end
end
