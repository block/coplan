# Copied from Rails' ActiveStorage install migration (active_storage 8.1) so
# the engine can ship attachment support without requiring hosts to run
# `bin/rails active_storage:install` themselves.
#
# Deliberate deviations from the stock migration:
#
# * The three active_storage tables keep ActiveStorage's stock auto-increment
#   bigint primary keys — ActiveStorage manages those rows itself and never
#   goes through CoPlan::ApplicationRecord#assign_uuid, so string UUID PKs
#   would be left blank on insert.
# * `active_storage_attachments.record_id` is `string, limit: 36` (instead of
#   bigint) because it's a polymorphic FK that must hold CoPlan's string UUID
#   primary keys (e.g. coplan_plans.id).
# * Table creation is guarded with `table_exists?` so hosts that already have
#   ActiveStorage don't blow up. Hosts that installed ActiveStorage via the
#   stock migration normally never receive this file (install:migrations
#   skips same-named migrations), but the guard also covers schema-loaded
#   databases. If a pre-existing active_storage_attachments table has a
#   non-string record_id, we warn loudly: CoPlan's UUID plan ids cannot be
#   stored in a bigint record_id column.
class CreateActiveStorageTables < ActiveRecord::Migration[8.1]
  # Ownership marker: `down` only drops tables carrying this comment, so a
  # rollback can never destroy ActiveStorage tables (and data) that the host
  # app created before installing CoPlan.
  OWNERSHIP_COMMENT = "Created by CoPlan engine".freeze

  def up
    unless table_exists?(:active_storage_blobs)
      create_table :active_storage_blobs, comment: OWNERSHIP_COMMENT do |t|
        t.string   :key,          null: false
        t.string   :filename,     null: false
        t.string   :content_type
        t.text     :metadata
        t.string   :service_name, null: false
        t.bigint   :byte_size,    null: false
        t.string   :checksum

        t.datetime :created_at, precision: 6, null: false

        t.index [ :key ], unique: true
      end
    end

    if table_exists?(:active_storage_attachments)
      record_id_type = columns(:active_storage_attachments).find { |c| c.name == "record_id" }&.type
      unless record_id_type == :string
        say "WARNING: active_storage_attachments.record_id is #{record_id_type.inspect}, not :string.", true
        say "CoPlan attachments store string(36) UUIDs in record_id and WILL NOT WORK until the column is widened.", true
        say "See the 'File attachments (ActiveStorage)' section of CoPlan's HOST_APP_GUIDE.md.", true
      end
    else
      create_table :active_storage_attachments, comment: OWNERSHIP_COMMENT do |t|
        t.string :name,        null: false
        t.string :record_type, null: false
        t.string :record_id,   null: false, limit: 36
        t.references :blob, null: false, type: :bigint

        t.datetime :created_at, precision: 6, null: false

        t.index [ :record_type, :record_id, :name, :blob_id ], name: :index_active_storage_attachments_uniqueness, unique: true
        t.foreign_key :active_storage_blobs, column: :blob_id
      end
    end

    unless table_exists?(:active_storage_variant_records)
      create_table :active_storage_variant_records, comment: OWNERSHIP_COMMENT do |t|
        t.belongs_to :blob, null: false, index: false, type: :bigint
        t.string :variation_digest, null: false

        t.index [ :blob_id, :variation_digest ], name: :index_active_storage_variant_records_uniqueness, unique: true
        t.foreign_key :active_storage_blobs, column: :blob_id
      end
    end
  end

  # Mirrors the stock ActiveStorage install migration's rollback, but only
  # for tables this migration actually created (identified by the ownership
  # comment set in `up`). Tables that pre-existed — the host app installed
  # ActiveStorage before CoPlan, so `up` skipped them — are left untouched:
  # dropping them would destroy host-owned data.
  def down
    [ :active_storage_variant_records, :active_storage_attachments, :active_storage_blobs ].each do |table|
      next unless table_exists?(table)

      if connection.table_comment(table) == OWNERSHIP_COMMENT
        drop_table table
      else
        say "Skipping drop of #{table}: not created by the CoPlan engine (no ownership comment).", true
      end
    end
  end
end
