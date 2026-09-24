ActiveAdmin.register CoPlan::NotificationDelivery, as: "NotificationDelivery" do
  actions :index, :show

  index do
    id_column
    column :notification
    column :channel
    column :status
    column :sent_at
    column :external_id
    column :created_at
    actions
  end

  filter :channel, as: :select, collection: CoPlan::NotificationDelivery::CHANNELS
  filter :status, as: :select, collection: CoPlan::NotificationDelivery::STATUSES
  filter :created_at

  show do
    attributes_table do
      row :id
      row :notification
      row :channel
      row :status
      row :sent_at
      row :external_id
      row :error_code
      row :created_at
      row :updated_at
    end
  end
end
