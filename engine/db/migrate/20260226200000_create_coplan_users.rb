class CreateCoplanUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :coplan_users, id: { type: :string, limit: 36 } do |t|
      t.string :external_id, null: false
      t.string :name, null: false
      t.boolean :admin, default: false, null: false
      t.json :metadata
      t.timestamps
    end

    add_index :coplan_users, :external_id, unique: true
  end
end
