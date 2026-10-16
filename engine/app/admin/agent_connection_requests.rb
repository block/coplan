ActiveAdmin.register CoPlan::AgentConnectionRequest, as: "AgentConnectionRequest" do
  actions :index, :show
  filter :name
  filter :status
  filter :user
  index do
    id_column
    column :name
    column :status
    column :user
    column :expires_at
    column :created_at
  end
  show do
    attributes_table do
      row :id
      row :name
      row :status
      row :user
      row :expires_at
      row :created_at
    end
  end
end
