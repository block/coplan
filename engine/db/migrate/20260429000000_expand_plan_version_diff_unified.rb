class ExpandPlanVersionDiffUnified < ActiveRecord::Migration[8.0]
  # The default `text` column tops out at ~64KB on MySQL, which we hit
  # whenever a PlanVersion's unified diff exceeds that — easy with the
  # PUT /api/v1/plans/:id/content endpoint, where agents can submit
  # whole-file rewrites of large plans. content_markdown is already
  # mediumtext (~16MB); diff_unified should match so any persistable
  # content can also persist its diff.
  def change
    change_column :coplan_plan_versions, :diff_unified, :text, limit: 16.megabytes - 1
  end
end
