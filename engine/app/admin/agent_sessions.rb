ActiveAdmin.register CoPlan::AgentSession, as: "AgentSession" do
  # Read-mostly: sessions are claimed and updated over the API. Destroy
  # stays available so an operator can clear a stuck row.
  actions :index, :show, :destroy

  index do
    selectable_column
    id_column
    column :agent_name
    column :plan
    column :api_token
    column :state
    column :state_detail
    column :last_activity_at
    column :wakes_answered_count
    column :wake_failures_count
    actions
  end

  show do
    attributes_table do
      row :id
      row :agent_name
      row :plan
      row :api_token
      row :state
      row :state_detail
      row :last_activity_at
      row :last_transport_at
      # wake_secret is deliberately not rendered — it's a credential.
      row :wake_url
      row :wakes_answered_count
      row :wake_failures_count
      row :created_at
      row :updated_at
    end
  end
end
