class CreateCoplanNotificationDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :coplan_notification_deliveries, id: { type: :string, limit: 36 } do |t|
      t.string :notification_id, limit: 36, null: false
      t.string :channel, null: false
      t.string :status, null: false
      t.datetime :sent_at
      t.string :external_id
      t.string :error_code
      t.timestamps
    end

    add_index :coplan_notification_deliveries, [ :notification_id, :channel ], unique: true,
      name: "index_coplan_notification_deliveries_on_notification_and_channel"
    add_index :coplan_notification_deliveries, [ :channel, :status, :created_at ],
      name: "index_coplan_notification_deliveries_on_channel_and_status"
    add_foreign_key :coplan_notification_deliveries, :coplan_notifications,
      column: :notification_id, on_delete: :cascade
  end
end
