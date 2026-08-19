class CreateAgentCollaborationTables < ActiveRecord::Migration[8.1]
  # Guarded because these objects may already exist on both sides of the
  # split this migration heals: databases loaded from schema.rb carry the
  # tables (they leaked into the schema via #175's regeneration against a
  # dev database), and api_tokens.agent_name ships with the identity
  # migration (20260815000000), which runs first on hosts that install
  # this one later.
  def change
    # Durable per-agent event inbox. IDs are UUIDv7 (time-ordered), so the
    # id doubles as the pagination cursor: "give me events after <id>".
    unless table_exists?(:coplan_agent_events)
      create_table :coplan_agent_events, id: { type: :string, limit: 36 } do |t|
        t.string :api_token_id, limit: 36, null: false
        t.string :plan_id, limit: 36, null: false
        t.string :comment_thread_id, limit: 36
        t.string :comment_id, limit: 36
        t.string :event_type, null: false
        t.json :payload
        t.datetime :acked_at
        t.datetime :created_at, null: false

        t.index [ :api_token_id, :id ]
        t.index [ :api_token_id, :acked_at ]
        t.index :plan_id
      end

      add_foreign_key :coplan_agent_events, :coplan_api_tokens, column: :api_token_id
      add_foreign_key :coplan_agent_events, :coplan_plans, column: :plan_id
    end

    # One session per (plan, agent token) — Linear-style delegation state
    # machine driving the presence pill: pending / active / awaiting_input /
    # complete / stale.
    unless table_exists?(:coplan_agent_sessions)
      create_table :coplan_agent_sessions, id: { type: :string, limit: 36 } do |t|
        t.string :plan_id, limit: 36, null: false
        t.string :api_token_id, limit: 36, null: false
        t.string :agent_name, null: false
        t.string :state, null: false, default: "pending"
        t.string :state_detail
        t.datetime :last_activity_at
        t.timestamps

        t.index [ :plan_id, :api_token_id ], unique: true
        t.index :api_token_id
      end

      add_foreign_key :coplan_agent_sessions, :coplan_api_tokens, column: :api_token_id
      add_foreign_key :coplan_agent_sessions, :coplan_plans, column: :plan_id
    end

    # Stable display identity for an agent token, instead of the free-text
    # per-comment agent_name. Normally added by 20260815000000 already.
    unless column_exists?(:coplan_api_tokens, :agent_name)
      add_column :coplan_api_tokens, :agent_name, :string
    end
  end
end
