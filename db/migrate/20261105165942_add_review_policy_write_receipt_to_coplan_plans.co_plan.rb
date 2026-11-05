# This migration comes from co_plan (originally 20261105170000)
class AddReviewPolicyWriteReceiptToCoplanPlans < ActiveRecord::Migration[8.1]
  def change
    add_column :coplan_plans, :review_policy_write_id, :string, limit: 36
    add_column :coplan_plans, :review_policy_write_sequence, :bigint
  end
end
