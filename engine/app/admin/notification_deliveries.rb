ActiveAdmin.register CoPlan::NotificationDelivery, as: "NotificationDelivery" do
  actions :index, :show

  index do
    id_column
    column("Recipient") { |delivery| delivery.notification.user }
    column("Plan") { |delivery| delivery.notification.plan }
    column("Reason") { |delivery| delivery.notification.reason }
    column :channel
    column :status
    column :sent_at
    column :external_id
    column :error_code
    column :created_at
    actions
  end

  filter :channel, as: :select, collection: CoPlan::NotificationDelivery::CHANNELS
  filter :status, as: :select, collection: CoPlan::NotificationDelivery::STATUSES
  filter :external_id
  filter :created_at

  show do
    attributes_table do
      row :id
      row :notification
      row("Recipient") { |delivery| delivery.notification.user }
      row("Plan") { |delivery| delivery.notification.plan }
      row("Reason") { |delivery| delivery.notification.reason }
      row :channel
      row :status
      row :sent_at
      row :external_id
      row :error_code
      row :created_at
      row :updated_at
    end
  end

  controller do
    def scoped_collection
      super.includes(notification: [ :user, :plan ])
    end
  end
end
