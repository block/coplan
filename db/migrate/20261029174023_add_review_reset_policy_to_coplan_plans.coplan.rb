# This migration comes from coplan (originally 20261029120000)
class AddReviewResetPolicyToCoplanPlans < ActiveRecord::Migration[8.1]
  def change
    add_column :coplan_plans, :reset_reviews_on_change, :boolean, null: false, default: true
  end
end
