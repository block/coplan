# This migration comes from co_plan (originally 20261118220000)
class PinComponentCatalogOnVersions < ActiveRecord::Migration[8.1]
  def change
    add_column :coplan_plan_versions, :component_catalog, :json
  end
end
