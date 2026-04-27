# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_22_202551) do
  create_table "active_admin_comments", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "author_id"
    t.string "author_type"
    t.text "body"
    t.datetime "created_at", null: false
    t.string "namespace"
    t.bigint "resource_id"
    t.string "resource_type"
    t.datetime "updated_at", null: false
    t.index ["author_type", "author_id"], name: "index_active_admin_comments_on_author"
    t.index ["namespace"], name: "index_active_admin_comments_on_namespace"
    t.index ["resource_type", "resource_id"], name: "index_active_admin_comments_on_resource"
  end

  create_table "coplan_api_tokens", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.timestamp "expires_at"
    t.timestamp "last_used_at"
    t.string "name", null: false
    t.timestamp "revoked_at"
    t.string "token_digest", null: false
    t.string "token_prefix", limit: 8
    t.datetime "updated_at", null: false
    t.string "user_id", limit: 36, null: false
    t.index ["token_digest"], name: "index_coplan_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_coplan_api_tokens_on_user_id"
  end

  create_table "coplan_automated_plan_reviewers", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "ai_model", null: false
    t.string "ai_provider", default: "openai", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "key", null: false
    t.string "name", null: false
    t.text "prompt_text", null: false
    t.json "trigger_statuses", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_coplan_automated_plan_reviewers_on_key", unique: true
  end

  create_table "coplan_comment_threads", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "addressed_in_plan_version_id", limit: 36
    t.text "anchor_context"
    t.integer "anchor_end"
    t.integer "anchor_revision"
    t.integer "anchor_start"
    t.text "anchor_text"
    t.datetime "created_at", null: false
    t.string "created_by_user_id", limit: 36, null: false
    t.integer "end_line"
    t.boolean "out_of_date", default: false, null: false
    t.string "out_of_date_since_version_id", limit: 36
    t.string "plan_id", limit: 36, null: false
    t.string "plan_version_id", limit: 36, null: false
    t.string "resolved_by_user_id", limit: 36
    t.integer "start_line"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["addressed_in_plan_version_id"], name: "fk_rails_e7003e0df7"
    t.index ["created_by_user_id"], name: "fk_rails_88fb5e06ca"
    t.index ["out_of_date_since_version_id"], name: "fk_rails_be37c1499d"
    t.index ["plan_id", "out_of_date"], name: "index_coplan_comment_threads_on_plan_id_and_out_of_date"
    t.index ["plan_id", "status"], name: "index_coplan_comment_threads_on_plan_id_and_status"
    t.index ["plan_version_id"], name: "fk_rails_676660f283"
    t.index ["resolved_by_user_id"], name: "fk_rails_8625e1eb43"
  end

  create_table "coplan_comments", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "agent_name"
    t.string "author_id", limit: 36
    t.string "author_type", null: false
    t.text "body_markdown", null: false
    t.string "comment_thread_id", limit: 36, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["comment_thread_id", "created_at"], name: "index_coplan_comments_on_comment_thread_id_and_created_at"
  end

  create_table "coplan_edit_leases", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.timestamp "expires_at", null: false
    t.string "holder_id", limit: 36
    t.string "holder_type", null: false
    t.timestamp "last_heartbeat_at", null: false
    t.string "lease_token_digest", null: false
    t.string "plan_id", limit: 36, null: false
    t.datetime "updated_at", null: false
    t.index ["plan_id"], name: "index_coplan_edit_leases_on_plan_id", unique: true
  end

  create_table "coplan_edit_sessions", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "actor_id", limit: 36
    t.string "actor_type", null: false
    t.integer "base_revision", null: false
    t.text "change_summary"
    t.timestamp "committed_at"
    t.datetime "created_at", null: false
    t.text "draft_content", size: :long
    t.timestamp "expires_at", null: false
    t.json "operations_json", null: false
    t.string "plan_id", limit: 36, null: false
    t.string "plan_version_id", limit: 36
    t.string "status", default: "open", null: false
    t.datetime "updated_at", null: false
    t.index ["plan_id", "status"], name: "index_coplan_edit_sessions_on_plan_id_and_status"
    t.index ["plan_version_id"], name: "fk_rails_14c3f0737b"
  end

  create_table "coplan_notifications", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "comment_id", limit: 36
    t.string "comment_thread_id", limit: 36, null: false
    t.datetime "created_at", null: false
    t.string "plan_id", limit: 36, null: false
    t.timestamp "read_at"
    t.string "reason", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", limit: 36, null: false
    t.index ["comment_id"], name: "fk_rails_c70f93334a"
    t.index ["comment_thread_id", "user_id"], name: "index_coplan_notifications_on_thread_and_user"
    t.index ["plan_id"], name: "index_coplan_notifications_on_plan_id"
    t.index ["user_id", "read_at"], name: "index_coplan_notifications_on_user_id_and_read_at"
  end

  create_table "coplan_plan_collaborators", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "added_by_user_id", limit: 36
    t.datetime "approved_at"
    t.datetime "created_at", null: false
    t.text "highlighted_reason"
    t.string "plan_id", limit: 36, null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", limit: 36, null: false
    t.index ["added_by_user_id"], name: "index_coplan_plan_collaborators_on_added_by_user_id"
    t.index ["plan_id", "user_id"], name: "index_coplan_plan_collaborators_on_plan_id_and_user_id", unique: true
    t.index ["plan_id"], name: "index_coplan_plan_collaborators_on_plan_id"
    t.index ["user_id"], name: "index_coplan_plan_collaborators_on_user_id"
  end

  create_table "coplan_plan_tags", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "plan_id", limit: 36, null: false
    t.string "tag_id", limit: 36, null: false
    t.datetime "updated_at", null: false
    t.index ["plan_id", "tag_id"], name: "index_coplan_plan_tags_on_plan_id_and_tag_id", unique: true
    t.index ["tag_id"], name: "index_coplan_plan_tags_on_tag_id"
  end

  create_table "coplan_plan_types", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "default_tags"
    t.text "description"
    t.json "metadata"
    t.string "name", null: false
    t.text "template_content"
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_coplan_plan_types_on_name", unique: true
  end

  create_table "coplan_plan_versions", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "actor_id", limit: 36
    t.string "actor_type", null: false
    t.string "ai_model"
    t.string "ai_provider"
    t.integer "base_revision"
    t.text "change_summary"
    t.text "content_markdown", size: :medium, null: false
    t.string "content_sha256", null: false
    t.timestamp "created_at", null: false
    t.text "diff_unified"
    t.json "operations_json"
    t.string "plan_id", limit: 36, null: false
    t.text "prompt_excerpt"
    t.text "reason"
    t.integer "revision", null: false
    t.index ["plan_id", "created_at"], name: "index_coplan_plan_versions_on_plan_id_and_created_at"
    t.index ["plan_id", "revision"], name: "index_coplan_plan_versions_on_plan_id_and_revision", unique: true
    t.index ["plan_id"], name: "index_coplan_plan_versions_on_plan_id"
  end

  create_table "coplan_plan_viewers", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_seen_at", null: false
    t.string "plan_id", limit: 36, null: false
    t.datetime "updated_at", null: false
    t.string "user_id", limit: 36, null: false
    t.index ["last_seen_at"], name: "index_coplan_plan_viewers_on_last_seen_at"
    t.index ["plan_id", "user_id"], name: "index_coplan_plan_viewers_on_plan_id_and_user_id", unique: true
    t.index ["user_id"], name: "fk_rails_6e3ee700a1"
  end

  create_table "coplan_plans", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by_user_id", limit: 36, null: false
    t.string "current_plan_version_id", limit: 36
    t.integer "current_revision", default: 0, null: false
    t.json "metadata"
    t.string "plan_type_id", limit: 36
    t.string "status", default: "brainstorm", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_coplan_plans_on_created_by_user_id"
    t.index ["current_plan_version_id"], name: "fk_rails_c401577583"
    t.index ["plan_type_id"], name: "index_coplan_plans_on_plan_type_id"
    t.index ["status"], name: "index_coplan_plans_on_status"
    t.index ["updated_at"], name: "index_coplan_plans_on_updated_at"
  end

  create_table "coplan_references", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key"
    t.string "plan_id", limit: 36, null: false
    t.string "reference_type", null: false
    t.string "source", null: false
    t.string "target_plan_id", limit: 36
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["plan_id", "key"], name: "index_coplan_references_on_plan_id_and_key", unique: true
    t.index ["plan_id", "url"], name: "index_coplan_references_on_plan_id_and_url", unique: true
    t.index ["source"], name: "index_coplan_references_on_source"
    t.index ["target_plan_id"], name: "index_coplan_references_on_target_plan_id"
  end

  create_table "coplan_tags", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "plans_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_coplan_tags_on_name", unique: true
  end

  create_table "coplan_users", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.string "email"
    t.string "external_id", null: false
    t.json "metadata"
    t.string "name", null: false
    t.json "notification_preferences"
    t.string "team"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["email"], name: "index_coplan_users_on_email", unique: true
    t.index ["external_id"], name: "index_coplan_users_on_external_id", unique: true
    t.index ["username"], name: "index_coplan_users_on_username", unique: true
  end

  add_foreign_key "coplan_api_tokens", "coplan_users", column: "user_id"
  add_foreign_key "coplan_comment_threads", "coplan_plan_versions", column: "addressed_in_plan_version_id"
  add_foreign_key "coplan_comment_threads", "coplan_plan_versions", column: "out_of_date_since_version_id"
  add_foreign_key "coplan_comment_threads", "coplan_plan_versions", column: "plan_version_id"
  add_foreign_key "coplan_comment_threads", "coplan_plans", column: "plan_id"
  add_foreign_key "coplan_comment_threads", "coplan_users", column: "created_by_user_id"
  add_foreign_key "coplan_comment_threads", "coplan_users", column: "resolved_by_user_id"
  add_foreign_key "coplan_comments", "coplan_comment_threads", column: "comment_thread_id"
  add_foreign_key "coplan_edit_leases", "coplan_plans", column: "plan_id"
  add_foreign_key "coplan_edit_sessions", "coplan_plan_versions", column: "plan_version_id"
  add_foreign_key "coplan_edit_sessions", "coplan_plans", column: "plan_id"
  add_foreign_key "coplan_notifications", "coplan_comment_threads", column: "comment_thread_id"
  add_foreign_key "coplan_notifications", "coplan_comments", column: "comment_id"
  add_foreign_key "coplan_notifications", "coplan_plans", column: "plan_id"
  add_foreign_key "coplan_notifications", "coplan_users", column: "user_id"
  add_foreign_key "coplan_plan_collaborators", "coplan_plans", column: "plan_id"
  add_foreign_key "coplan_plan_collaborators", "coplan_users", column: "added_by_user_id"
  add_foreign_key "coplan_plan_collaborators", "coplan_users", column: "user_id"
  add_foreign_key "coplan_plan_tags", "coplan_plans", column: "plan_id"
  add_foreign_key "coplan_plan_tags", "coplan_tags", column: "tag_id"
  add_foreign_key "coplan_plan_versions", "coplan_plans", column: "plan_id"
  add_foreign_key "coplan_plan_viewers", "coplan_plans", column: "plan_id"
  add_foreign_key "coplan_plan_viewers", "coplan_users", column: "user_id"
  add_foreign_key "coplan_plans", "coplan_plan_types", column: "plan_type_id"
  add_foreign_key "coplan_plans", "coplan_plan_versions", column: "current_plan_version_id"
  add_foreign_key "coplan_plans", "coplan_users", column: "created_by_user_id"
  add_foreign_key "coplan_references", "coplan_plans", column: "plan_id"
  add_foreign_key "coplan_references", "coplan_plans", column: "target_plan_id"
end
