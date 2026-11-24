# The historical migration name is retained for hosts that already installed it.
# Deleted comment content must remain in the database until an admin explicitly
# deletes it permanently. This migration only installs the comment lookup index.
class ScrubDeletedCommentBodies < ActiveRecord::Migration[8.1]
  def up
    add_index :coplan_agent_events, :comment_id unless index_exists?(:coplan_agent_events, :comment_id)
  end

  def down
    remove_index :coplan_agent_events, :comment_id if index_exists?(:coplan_agent_events, :comment_id)
  end
end
