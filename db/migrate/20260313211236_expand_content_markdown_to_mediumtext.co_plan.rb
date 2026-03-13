# This migration comes from co_plan (originally 20260313210000)
class ExpandContentMarkdownToMediumtext < ActiveRecord::Migration[8.0]
  def up
    change_column :coplan_plan_versions, :content_markdown, :text, limit: 16.megabytes - 1, null: false
  end

  def down
    change_column :coplan_plan_versions, :content_markdown, :text, null: false
  end
end
