# This migration comes from co_plan (originally 20260815000001)
class AddAgentNameToPlanHistory < ActiveRecord::Migration[8.1]
  def change
    # Comments already record which agent acted for a user (author_id is the
    # human, agent_name is the agent). Versions and events stored only
    # actor_type, so the history tab rendered an agent's edit as the human's.
    # Existing rows stay nil — they were written before the distinction was
    # captured and cannot be attributed retroactively.
    add_column :coplan_plan_versions, :agent_name, :string
    add_column :coplan_plan_events, :agent_name, :string
  end
end
