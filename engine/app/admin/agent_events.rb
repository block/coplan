ActiveAdmin.register CoPlan::AgentEvent, as: "AgentEvent" do
  # Inbox rows are written by the platform and acked by agents; admin is
  # for inspection only (a stuck inbox, a delivery question).
  actions :index, :show

  index do
    id_column
    column :event_type
    column :plan
    column :api_token
    column :acked_at
    column :created_at
  end

  show do
    attributes_table do
      row :id
      row :event_type
      row :plan
      row :api_token
      row :comment_thread_id
      row :comment_id
      row :payload
      row :acked_at
      row :created_at
    end
  end
end
