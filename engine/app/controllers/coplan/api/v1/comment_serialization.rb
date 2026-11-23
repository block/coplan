module Coplan
  module Api
    module V1
      module CommentSerialization
        private

        def comment_json(comment)
          result = {
            id: comment.id, author_type: comment.author_type, author_id: comment.author_id,
            agent_name: comment.agent_name, body_markdown: comment.body_markdown, deleted: comment.deleted?,
            created_at: comment.created_at, reactions: CommentReaction.as_api_json(comment), attachments: []
          }
          if comment.component_annotation?
            result[:component_selection] = comment.component_selection.except("image")
            if comment.component_selection["image"]
              result[:attachments] << { type: "component_snapshot", content_type: "image/png",
                download_url: api_v1_plan_comment_attachment_path(@plan, comment, "component_snapshot") }
            end
          end
          result
        end
      end
    end
  end
end
