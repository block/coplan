# Comments deleted before Comments::SoftDelete blanked them still hold their
# text in three places: the comment row, the comment_deleted history event's
# body_preview, and agent events queued for the comment. Each step is one
# idempotent UPDATE per row with no model code, so a rerun is harmless and no
# row's content can fail it.
class ScrubDeletedCommentBodies < ActiveRecord::Migration[8.1]
  DELETED_BODY = "_This comment was deleted._".freeze

  class Comment < ActiveRecord::Base
    self.table_name = "coplan_comments"
  end

  class PlanEvent < ActiveRecord::Base
    self.table_name = "coplan_plan_events"
  end

  class AgentEvent < ActiveRecord::Base
    self.table_name = "coplan_agent_events"
  end

  def up
    # Deleting a comment now looks up its agent events.
    add_index :coplan_agent_events, :comment_id unless index_exists?(:coplan_agent_events, :comment_id)

    deleted = Comment.where.not(deleted_at: nil)
    deleted.where.not(body_markdown: DELETED_BODY).update_all(body_markdown: DELETED_BODY)

    PlanEvent.where(event_type: "comment_deleted").find_each do |event|
      metadata = event.metadata
      next unless metadata.is_a?(Hash) && metadata.key?("body_preview")

      event.update_columns(metadata: metadata.except("body_preview"))
    end

    AgentEvent.where(comment_id: deleted.select(:id)).find_each do |event|
      payload = event.payload
      next unless payload.is_a?(Hash) && payload.key?("comment_body") && payload["comment_body"] != DELETED_BODY

      event.update_columns(payload: payload.merge("comment_body" => DELETED_BODY))
    end
  end

  def down
    # The deleted text is gone on purpose; only the index comes back out.
    remove_index :coplan_agent_events, :comment_id if index_exists?(:coplan_agent_events, :comment_id)
  end
end
