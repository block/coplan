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
# * Everything is wrapped in `unless table_exists?` guards so hosts that have
#   already installed ActiveStorage (with their own record_id type) don't
#   blow up when they copy the engine's migrations.
class CreateActiveStorageTables < ActiveRecord::Migration[8.1]
  def change
    unless table_exists?(:active_storage_blobs)
      create_table :active_storage_blobs do |t|
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

    unless table_exists?(:active_storage_attachments)
      create_table :active_storage_attachments do |t|
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
      create_table :active_storage_variant_records do |t|
        t.belongs_to :blob, null: false, index: false, type: :bigint
        t.string :variation_digest, null: false

        t.index [ :blob_id, :variation_digest ], name: :index_active_storage_variant_records_uniqueness, unique: true
        t.foreign_key :active_storage_blobs, column: :blob_id
      end
    end
  end
end
