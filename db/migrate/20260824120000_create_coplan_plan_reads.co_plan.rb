# This migration comes from co_plan (originally 20260824000000)
class CreateCoplanPlanReads < ActiveRecord::Migration[8.1]
  # Read receipts: the highest revision of a plan a given credential has
  # actually fetched content for. This is what makes "the agent hasn't
  # seen the human's edit yet" a fact the server can check, rather than a
  # number the caller asserts. See Plans::HumanEditGuard.
  def change
    create_table :coplan_plan_reads, id: { type: :string, limit: 36 } do |t|
      t.string :plan_id, limit: 36, null: false
      # "api_token" for agents, "user" for hook-authenticated humans.
      t.string :reader_type, null: false
      t.string :reader_id, limit: 36, null: false
      t.integer :last_seen_revision, null: false, default: 0
      t.datetime :last_seen_at, null: false
      t.timestamps
    end

    add_index :coplan_plan_reads, [ :plan_id, :reader_type, :reader_id ],
      unique: true, name: "index_coplan_plan_reads_on_plan_and_reader"
    add_foreign_key :coplan_plan_reads, :coplan_plans, column: :plan_id
  end
end
