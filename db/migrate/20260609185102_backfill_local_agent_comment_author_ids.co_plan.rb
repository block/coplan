# This migration comes from co_plan (originally 20260609000000)
class BackfillLocalAgentCommentAuthorIds < ActiveRecord::Migration[8.1]
  # For local_agent comments whose author_id still points at a
  # coplan_api_tokens.id, rewrite it to that token's user_id. This
  # pairs with the model change in engine/app/models/coplan/comment.rb:
  # Comment#author now resolves via a direct find_by(id:) for both
  # human and local_agent comments instead of joining coplan_api_tokens.
  #
  # Idempotent: once author_id holds a user UUID it won't match any
  # coplan_api_tokens.id, so re-runs skip those rows.
  def up
    CoPlan::Comment.where(author_type: "local_agent").find_each do |comment|
      token = CoPlan::ApiToken.find_by(id: comment.author_id)
      next unless token

      comment.update_columns(author_id: token.user_id) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def down
    # no-op (not reversible)
  end
end
