class PreserveCoplanReviewAssignments < ActiveRecord::Migration[8.1]
  def up
    # NULL releases the unique slot for ended assignments on MySQL and PostgreSQL.
    add_column :coplan_review_requests, :current_assignment, :boolean, default: true
    add_index :coplan_review_requests, [ :plan_id, :reviewer_id, :current_assignment ],
      unique: true, name: "index_coplan_reviews_on_current_assignment"
    remove_index :coplan_review_requests, [ :plan_id, :reviewer_id ]
  end

  def down
    # Multiple preserved assignments cannot fit the former uniqueness constraint.
    raise ActiveRecord::IrreversibleMigration, "Preserved review history cannot be discarded safely"
  end
end
