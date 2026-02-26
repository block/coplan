ActiveAdmin.register CoPlan::EditSession, as: "EditSession" do
  menu parent: "Plans"

  index do
    selectable_column
    id_column
    column :plan
    column :actor_type
    column :status
    column :base_revision
    column :expires_at
    column :committed_at
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :plan
      row :organization
      row :actor_type
      row :actor_id
      row :status
      row :base_revision
      row :change_summary
      row :expires_at
      row :committed_at
      row :plan_version
      row :created_at
      row :updated_at
    end
    panel "Operations JSON" do
      pre JSON.pretty_generate(edit_session.operations_json)
    end
  end
end
