# This migration comes from co_plan (originally 20260921000000)
class CreateCoplanAgentHarnesses < ActiveRecord::Migration[8.1]
  class MigrationHarness < ActiveRecord::Base
    self.table_name = "coplan_agent_harnesses"
  end

  class MigrationComment < ActiveRecord::Base
    self.table_name = "coplan_comments"
  end

  class MigrationToken < ActiveRecord::Base
    self.table_name = "coplan_api_tokens"
  end

  def up
    create_table :coplan_agent_harnesses, id: :string, limit: 36 do |t|
      t.string :key, null: false
      t.string :display_name, null: false
      t.string :icon_url
      t.timestamps
    end
    add_index :coplan_agent_harnesses, :key, unique: true

    add_reference :coplan_comments, :agent_harness, type: :string, limit: 36,
      foreign_key: { to_table: :coplan_agent_harnesses }

    backfill_harnesses
  end

  def down
    remove_reference :coplan_comments, :agent_harness,
      foreign_key: { to_table: :coplan_agent_harnesses }
    drop_table :coplan_agent_harnesses
  end

  private

  def backfill_harnesses
    MigrationComment.where(author_type: %w[local_agent cloud_persona]).find_each do |comment|
      token = MigrationToken.find_by(id: comment.api_token_id)
      metadata = token ? token.metadata.to_h : {}
      identity = metadata["harness"].presence || comment.agent_name.presence || "agent"
      key = canonical_key(identity)
      harness = MigrationHarness.find_or_create_by!(key: key) do |record|
        record.id = SecureRandom.uuid
        record.display_name = default_display_name(key, identity)
      end
      comment.update_columns(agent_harness_id: harness.id)
    end
  end

  def default_display_name(key, identity)
    return "Amp" if key == "amp"
    return "Claude" if key == "claude-code"

    identity.to_s.titleize.presence || "Agent"
  end

  def canonical_key(identity)
    normalized = identity.to_s.downcase
    return "amp" if normalized.match?(/\bamp\b/)
    return "claude-code" if normalized.include?("claude")

    normalized.parameterize.presence || "agent"
  end
end
