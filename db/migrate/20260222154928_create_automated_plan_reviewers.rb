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

    add_index :automated_plan_reviewers, [ :organization_id, :key ], unique: true
    add_foreign_key :automated_plan_reviewers, :organizations
  end
end
