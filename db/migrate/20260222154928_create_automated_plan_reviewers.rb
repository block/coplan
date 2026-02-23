class CreateAutomatedPlanReviewers < ActiveRecord::Migration[8.1]
  def change
    create_table :automated_plan_reviewers, id: :uuid do |t|
      t.column :organization_id, :uuid, null: true
      t.string :key, null: false
      t.string :name, null: false
      t.string :prompt_path, null: false
      t.boolean :enabled, null: false, default: true
      t.json :trigger_statuses, null: false
      t.string :ai_provider, null: false, default: "openai"
      t.string :ai_model, null: false
      t.timestamps
    end

    # MySQL treats multiple NULLs as distinct in a UNIQUE index, so a plain
    # index on [:organization_id, :key] would allow duplicate keys for global
    # reviewers (organization_id IS NULL). The virtual column substitutes NULL
    # with the sentinel 'global' so the unique constraint is enforced correctly.
    add_column :automated_plan_reviewers, :organization_scope, :virtual,
      type: :string, as: "COALESCE(`organization_id`, 'global')", stored: true
    add_index :automated_plan_reviewers, [ :organization_scope, :key ], unique: true
    add_foreign_key :automated_plan_reviewers, :organizations
  end
end
