# This migration comes from co_plan (originally 20260813000001)
class CreateCoplanLibraryEvents < ActiveRecord::Migration[8.1]
  def change
    # Append-only audit log for a library's organization: who filed/moved/
    # removed which plan, and who created/renamed/moved/deleted folders —
    # with actor_type distinguishing humans from agents. Mirrors
    # coplan_plan_events, but scoped to the library (the shelf), not the
    # plan (the document).
    #
    # plan_id / folder_id are deliberately not foreign keys: audit rows must
    # survive the deletion of what they describe. Paths and titles are
    # denormalized into before/after/metadata so the log stays readable.
    create_table :coplan_library_events, id: { type: :string, limit: 36 } do |t|
      t.string :library_id, limit: 36, null: false
      t.string :actor_id, limit: 36
      t.string :actor_type, null: false
      t.string :event_type, null: false
      t.string :plan_id, limit: 36
      t.string :folder_id, limit: 36
      # Groups every event applied by one bulk organize call, so a
      # 2,000-move run reads as one entry point in the log, not noise.
      t.string :run_id, limit: 36
      t.text :before_value
      t.text :after_value
      t.json :metadata
      t.datetime :created_at, null: false

      t.index [ :library_id, :created_at ]
      t.index :plan_id
      t.index :event_type
      t.index :run_id
    end

    add_foreign_key :coplan_library_events, :coplan_libraries, column: :library_id
  end
end
