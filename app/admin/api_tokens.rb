ActiveAdmin.register CoPlan::ApiToken, as: "ApiToken" do
  permit_params :name, :user_id

  index do
    selectable_column
    id_column
    column :name
    column :user
    column :organization
    column :last_used_at
    column :revoked_at
    column :expires_at
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :name
      row :user
      row :organization
      row :token_digest
      row :last_used_at
      row :revoked_at
      row :expires_at
      row :created_at
      row :updated_at
    end
  end
end
