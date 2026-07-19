# This migration comes from co_plan (originally 20260719000000)
class AddWorkspaceScaleIndexes < ActiveRecord::Migration[8.1]
  # The workspace's hot paths at scale (50k–1M+ plans):
  #
  # * Sidebar folder counts: placements filtered by library, grouped by
  #   folder — a covering index answers it without touching the table.
  # * "Mine" lists: created_by_user + ORDER BY updated_at — a composite
  #   index sorts without a filesort.
  # * Org-wide lists/feeds: visibility + ORDER BY updated_at, same idea.
  #
  # The single-column indexes these overlap (library_id, visibility) stay:
  # other queries (uniqueness upserts, admin filters) still want them.
  def change
    add_index :coplan_plan_placements, [ :library_id, :folder_id, :plan_id ],
      name: "index_coplan_placements_covering_folder_counts"
    add_index :coplan_plans, [ :created_by_user_id, :updated_at ],
      name: "index_coplan_plans_on_author_and_updated_at"
    add_index :coplan_plans, [ :visibility, :updated_at ],
      name: "index_coplan_plans_on_visibility_and_updated_at"
  end
end
