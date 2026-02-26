ActiveAdmin.register User do
  permit_params :email, :name, :role

  index do
    selectable_column
    id_column
    column :name
    column :email
    column :role
    column :last_sign_in_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :name
      row :email
      row :role
      row :oidc_provider
      row :last_sign_in_at
      row :created_at
      row :updated_at
    end
  end
end
