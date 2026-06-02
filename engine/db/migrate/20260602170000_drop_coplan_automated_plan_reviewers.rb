class DropCoplanAutomatedPlanReviewers < ActiveRecord::Migration[8.0]
  def up
    drop_table :coplan_automated_plan_reviewers
  end

  def down
    create_table :coplan_automated_plan_reviewers, id: { type: :string, limit: 36 } do |t|
      t.string :key, null: false
      t.string :name, null: false
      t.text :prompt_text, null: false
      t.string :ai_provider, default: "openai", null: false
      t.string :ai_model, null: false
      t.json :trigger_statuses, null: false
      t.boolean :enabled, default: true, null: false
      t.timestamps
    end

    add_index :coplan_automated_plan_reviewers, :key, unique: true
  end
end
