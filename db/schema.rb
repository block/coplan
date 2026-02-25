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

ActiveRecord::Schema[8.1].define(version: 2026_02_25_200001) do
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

  create_table "api_tokens", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.timestamp "expires_at"
    t.timestamp "last_used_at"
    t.string "name", null: false
    t.string "organization_id", limit: 36, null: false
    t.timestamp "revoked_at"
    t.string "token_digest", null: false
    t.string "token_prefix", limit: 8
    t.datetime "updated_at", null: false
    t.string "user_id", limit: 36, null: false
    t.index ["organization_id"], name: "fk_rails_701d89e8df"
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "automated_plan_reviewers", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "ai_model", null: false
    t.string "ai_provider", default: "openai", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "key", null: false
    t.string "name", null: false
    t.string "organization_id", limit: 36, null: false
    t.text "prompt_text", null: false
    t.json "trigger_statuses", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "key"], name: "index_automated_plan_reviewers_on_organization_id_and_key", unique: true
  end

  create_table "comment_threads", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "addressed_in_plan_version_id", limit: 36
    t.text "anchor_context"
    t.integer "anchor_end"
    t.integer "anchor_revision"
    t.integer "anchor_start"
    t.text "anchor_text"
    t.datetime "created_at", null: false
    t.string "created_by_user_id", limit: 36, null: false
    t.integer "end_line"
    t.string "organization_id", limit: 36, null: false
    t.boolean "out_of_date", default: false, null: false
    t.string "out_of_date_since_version_id", limit: 36
    t.string "plan_id", limit: 36, null: false
    t.string "plan_version_id", limit: 36, null: false
    t.string "resolved_by_user_id", limit: 36
    t.integer "start_line"
    t.string "status", default: "open", null: false
    t.datetime "updated_at", null: false
    t.index ["addressed_in_plan_version_id"], name: "fk_rails_e7003e0df7"
    t.index ["created_by_user_id"], name: "fk_rails_88fb5e06ca"
    t.index ["organization_id"], name: "fk_rails_d5cb7ddf86"
    t.index ["out_of_date_since_version_id"], name: "fk_rails_be37c1499d"
    t.index ["plan_id", "out_of_date"], name: "index_comment_threads_on_plan_id_and_out_of_date"
    t.index ["plan_id", "status"], name: "index_comment_threads_on_plan_id_and_status"
    t.index ["plan_version_id"], name: "fk_rails_676660f283"
    t.index ["resolved_by_user_id"], name: "fk_rails_8625e1eb43"
  end

  create_table "comments", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "agent_name"
    t.string "author_id", limit: 36
    t.string "author_type", null: false
    t.text "body_markdown", null: false
    t.string "comment_thread_id", limit: 36, null: false
    t.datetime "created_at", null: false
    t.string "organization_id", limit: 36, null: false
    t.datetime "updated_at", null: false
    t.index ["comment_thread_id", "created_at"], name: "index_comments_on_comment_thread_id_and_created_at"
    t.index ["organization_id"], name: "fk_rails_b5b64d6bc9"
  end

  create_table "edit_leases", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.timestamp "expires_at", null: false
    t.string "holder_id", limit: 36
    t.string "holder_type", null: false
    t.timestamp "last_heartbeat_at", null: false
    t.string "lease_token_digest", null: false
    t.string "organization_id", limit: 36, null: false
    t.string "plan_id", limit: 36, null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "fk_rails_3f7fc284d2"
    t.index ["plan_id"], name: "index_edit_leases_on_plan_id", unique: true
  end

  create_table "edit_sessions", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "actor_id", limit: 36
    t.string "actor_type", null: false
    t.integer "base_revision", null: false
    t.text "change_summary"
    t.timestamp "committed_at"
    t.datetime "created_at", null: false
    t.text "draft_content", size: :long
    t.timestamp "expires_at", null: false
    t.json "operations_json", null: false
    t.string "organization_id", limit: 36, null: false
    t.string "plan_id", limit: 36, null: false
    t.string "plan_version_id", limit: 36
    t.string "status", default: "open", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_edit_sessions_on_organization_id"
    t.index ["plan_id", "status"], name: "index_edit_sessions_on_plan_id_and_status"
    t.index ["plan_version_id"], name: "fk_rails_14c3f0737b"
  end

  create_table "organizations", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.json "allowed_email_domains"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "slack_webhook_url"
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
  end

  create_table "plan_collaborators", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "added_by_user_id", limit: 36
    t.datetime "created_at", null: false
    t.string "organization_id", limit: 36, null: false
    t.string "plan_id", limit: 36, null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.string "user_id", limit: 36, null: false
    t.index ["added_by_user_id"], name: "index_plan_collaborators_on_added_by_user_id"
    t.index ["organization_id"], name: "index_plan_collaborators_on_organization_id"
    t.index ["plan_id", "user_id"], name: "index_plan_collaborators_on_plan_id_and_user_id", unique: true
    t.index ["plan_id"], name: "index_plan_collaborators_on_plan_id"
    t.index ["user_id"], name: "index_plan_collaborators_on_user_id"
  end

  create_table "plan_versions", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "actor_id", limit: 36
    t.string "actor_type", null: false
    t.string "ai_model"
    t.string "ai_provider"
    t.integer "base_revision"
    t.text "change_summary"
    t.text "content_markdown", null: false
    t.string "content_sha256", null: false
    t.timestamp "created_at", null: false
    t.text "diff_unified"
    t.json "operations_json"
    t.string "organization_id", limit: 36, null: false
    t.string "plan_id", limit: 36, null: false
    t.text "prompt_excerpt"
    t.text "reason"
    t.integer "revision", null: false
    t.index ["organization_id"], name: "index_plan_versions_on_organization_id"
    t.index ["plan_id", "created_at"], name: "index_plan_versions_on_plan_id_and_created_at"
    t.index ["plan_id", "revision"], name: "index_plan_versions_on_plan_id_and_revision", unique: true
    t.index ["plan_id"], name: "index_plan_versions_on_plan_id"
  end

  create_table "plans", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by_user_id", limit: 36, null: false
    t.string "current_plan_version_id", limit: 36
    t.integer "current_revision", default: 0, null: false
    t.json "metadata"
    t.string "organization_id", limit: 36, null: false
    t.string "status", default: "brainstorm", null: false
    t.json "tags"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_plans_on_created_by_user_id"
    t.index ["current_plan_version_id"], name: "fk_rails_c401577583"
    t.index ["organization_id", "status"], name: "index_plans_on_organization_id_and_status"
    t.index ["organization_id", "updated_at"], name: "index_plans_on_organization_id_and_updated_at"
    t.index ["organization_id"], name: "index_plans_on_organization_id"
  end

  create_table "users", id: { type: :string, limit: 36 }, charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.timestamp "last_sign_in_at"
    t.string "name", null: false
    t.string "oidc_provider"
    t.string "oidc_sub"
    t.string "org_role", default: "member", null: false
    t.string "organization_id", limit: 36, null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "email"], name: "index_users_on_organization_id_and_email", unique: true
    t.index ["organization_id"], name: "index_users_on_organization_id"
  end

  add_foreign_key "api_tokens", "organizations"
  add_foreign_key "api_tokens", "users"
  add_foreign_key "automated_plan_reviewers", "organizations"
  add_foreign_key "comment_threads", "organizations"
  add_foreign_key "comment_threads", "plan_versions"
  add_foreign_key "comment_threads", "plan_versions", column: "addressed_in_plan_version_id"
  add_foreign_key "comment_threads", "plan_versions", column: "out_of_date_since_version_id"
  add_foreign_key "comment_threads", "plans"
  add_foreign_key "comment_threads", "users", column: "created_by_user_id"
  add_foreign_key "comment_threads", "users", column: "resolved_by_user_id"
  add_foreign_key "comments", "comment_threads"
  add_foreign_key "comments", "organizations"
  add_foreign_key "edit_leases", "organizations"
  add_foreign_key "edit_leases", "plans"
  add_foreign_key "edit_sessions", "organizations"
  add_foreign_key "edit_sessions", "plan_versions"
  add_foreign_key "edit_sessions", "plans"
  add_foreign_key "plan_collaborators", "organizations"
  add_foreign_key "plan_collaborators", "plans"
  add_foreign_key "plan_collaborators", "users"
  add_foreign_key "plan_collaborators", "users", column: "added_by_user_id"
  add_foreign_key "plan_versions", "organizations"
  add_foreign_key "plan_versions", "plans"
  add_foreign_key "plans", "organizations"
  add_foreign_key "plans", "plan_versions", column: "current_plan_version_id"
  add_foreign_key "plans", "users", column: "created_by_user_id"
  add_foreign_key "users", "organizations"
end
