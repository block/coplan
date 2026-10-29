# This migration comes from co_plan (originally 20261029000000)
class BindReviewCyclesToVersions < ActiveRecord::Migration[8.1]
  def up
    add_column :coplan_plans, :review_sequence, :bigint, null: false, default: 0
    add_column :coplan_review_requests, :generation, :bigint, null: false, default: 1
    add_column :coplan_review_requests, :current_response_id, :string, limit: 36
    add_column :coplan_review_requests, :reset_reason, :string
    add_column :coplan_review_responses, :request_generation, :bigint
    add_column :coplan_review_responses, :decision_sequence, :bigint
    add_index :coplan_review_requests, :current_response_id
    add_foreign_key :coplan_review_requests, :coplan_review_responses, column: :current_response_id, on_delete: :nullify
    # Old timestamps cannot prove which request cycle a response completed.
    # Keep those receipts as history; require a fresh decision for active tasks.
    execute "UPDATE coplan_review_requests SET generation = 2"
    execute "UPDATE coplan_review_requests SET status = 'pending', reset_reason = 'legacy_history' WHERE status <> 'withdrawn'"
  end

  def down
    remove_foreign_key :coplan_review_requests, column: :current_response_id
    remove_column :coplan_review_requests, :current_response_id
    remove_column :coplan_review_requests, :generation
    remove_column :coplan_review_requests, :reset_reason
    remove_column :coplan_review_responses, :request_generation
    remove_column :coplan_review_responses, :decision_sequence
    remove_column :coplan_plans, :review_sequence
  end
end
