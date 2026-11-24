# This migration comes from coplan (originally 20261123151500)
class RenameCoplanClassNames < ActiveRecord::Migration[8.1]
  LEGACY_PREFIX = "CoPlan::".freeze
  CURRENT_PREFIX = "Coplan::".freeze
  LEGACY_STORAGE_COMMENT = "Created by CoPlan engine".freeze
  CURRENT_STORAGE_COMMENT = "Created by Coplan engine".freeze

  TYPE_COLUMNS = {
    coplan_libraries: %i[owner_type],
    active_storage_attachments: %i[record_type],
    active_admin_comments: %i[author_type resource_type]
  }.freeze

  STORAGE_TABLES = %i[active_storage_attachments active_storage_blobs active_storage_variant_records].freeze

  def up
    rename_types(from: LEGACY_PREFIX, to: CURRENT_PREFIX)
    rename_storage_comments(from: LEGACY_STORAGE_COMMENT, to: CURRENT_STORAGE_COMMENT)
  end

  def down
    rename_types(from: CURRENT_PREFIX, to: LEGACY_PREFIX)
    rename_storage_comments(from: CURRENT_STORAGE_COMMENT, to: LEGACY_STORAGE_COMMENT)
  end

  private

  def rename_types(from:, to:)
    TYPE_COLUMNS.each do |table, columns|
      next unless table_exists?(table)

      quoted_table = connection.quote_table_name(table)
      columns.each do |name|
        column = connection.quote_column_name(name)
        execute <<~SQL
          UPDATE #{quoted_table}
          SET #{column} = CONCAT(#{connection.quote(to)}, SUBSTRING(#{column}, #{from.length + 1}))
          WHERE #{column} LIKE #{connection.quote("#{from}%")}
        SQL
      end
    end
  end

  def rename_storage_comments(from:, to:)
    return unless connection.supports_comments?

    STORAGE_TABLES.each do |table|
      next unless table_exists?(table) && connection.table_comment(table) == from

      change_table_comment(table, to)
    end
  end
end
