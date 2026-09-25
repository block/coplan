ActiveAdmin.register CoPlan::Notification, as: "Notification" do
  actions :index, :show

  index do
    id_column
    column :user
    column :plan
    column :reason
    column :read_at
    column :created_at
    actions
  end

  filter :reason, as: :select, collection: CoPlan::Notification::REASONS
  filter :user
  filter :plan
  filter :created_at

  show do
    attributes_table do
      row :id
      row :user
      row :plan
      row :comment_thread
      row :comment
      row :reason
      row :read_at
      row :created_at
    end

    panel "Deliveries" do
      table_for resource.notification_deliveries.order(created_at: :desc) do
        column :channel
        column :status
        column :sent_at
        column :error_code
        column("Details") { |delivery| link_to("View", admin_notification_delivery_path(delivery)) }
      end
    end
  end
end
