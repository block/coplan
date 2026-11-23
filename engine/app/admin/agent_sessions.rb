ActiveAdmin.register Coplan::AgentSession, as: "AgentSession" do
  # Read-mostly: sessions are claimed and updated over the API. Destroy
  # stays available so an operator can clear a stuck row.
  actions :index, :show, :destroy

  filter :agent_name
  filter :state
  filter :plan_id
  filter :created_at

  # No CSV, XML or JSON downloads: they serialize every column, including
  # the wake_secret credential the show page leaves out.
  index download_links: false do
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
