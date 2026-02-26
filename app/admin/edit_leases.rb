ActiveAdmin.register CoPlan::EditLease, as: "EditLease" do
  permit_params :plan_id, :holder_type, :holder_id

  index do
    selectable_column
    id_column
    column :plan
    column :organization
    column :holder_type
    column :holder_id
    column :expires_at
    column :last_heartbeat_at
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :plan
      row :organization
      row :holder_type
      row :holder_id
      row :lease_token_digest
      row :expires_at
      row :last_heartbeat_at
      row :created_at
      row :updated_at
    end
  end
end
