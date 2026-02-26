class RemoveOrganizations < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :users, :organizations

    remove_index :users, [:organization_id, :email]
    remove_index :users, :organization_id
    remove_column :users, :organization_id

    rename_column :users, :org_role, :role

    add_index :users, :email, unique: true

    drop_table :organizations
  end

  def down
    create_table :organizations, id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci" do |t|
      t.json :allowed_email_domains
      t.string :name, null: false
      t.text :slack_webhook_url
      t.string :slug, null: false
      t.timestamps
      t.index :slug, unique: true
    end

    rename_column :users, :role, :org_role

    remove_index :users, :email

    add_column :users, :organization_id, :string, limit: 36, null: true
    add_index :users, :organization_id
    add_index :users, [:organization_id, :email], unique: true
    add_foreign_key :users, :organizations
  end
end
