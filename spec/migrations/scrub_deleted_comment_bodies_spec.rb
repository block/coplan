require "rails_helper"
require CoPlan::Engine.root.join("db/migrate/20261120230000_scrub_deleted_comment_bodies.rb")

RSpec.describe ScrubDeletedCommentBodies do
  subject(:migration) { described_class.new }

  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }
  let(:thread) { create(:comment_thread, plan: plan, created_by_user: user) }
  let(:token) { create(:api_token, user: user) }

  before { migration.verbose = false }

  # Rows as the code before this change left them: deleted_at set, text kept.
  def legacy_deleted_comment(body)
    comment = create(:comment, comment_thread: thread, author_type: "human", author_id: user.id, body_markdown: body)
    comment.update_column(:deleted_at, Time.current)
    CoPlan::PlanEvent.create!(plan: plan, event_type: "comment_deleted", actor_type: "human", actor_id: user.id,
      metadata: { "comment_id" => comment.id, "thread_id" => thread.id, "body_preview" => body })
    CoPlan::AgentEvent.create!(api_token: token, plan: plan, comment_thread_id: thread.id, comment_id: comment.id,
      event_type: "comment.created", payload: { "comment_body" => body })
    comment
  end

  it "removes deleted comments' text from the row, the history event and queued agent events, and can rerun" do
    deleted = legacy_deleted_comment("Retracted salary numbers")
    kept = create(:comment, comment_thread: thread, author_type: "human", author_id: user.id, body_markdown: "Still here")

    migration.up
    migration.up

    expect(deleted.reload.body_markdown).to eq(CoPlan::Comment::DELETED_BODY)
    expect(kept.reload.body_markdown).to eq("Still here")
    stored = [ CoPlan::PlanEvent.where(plan: plan).pluck(:metadata), CoPlan::AgentEvent.where(plan: plan).pluck(:payload) ].to_json
    expect(stored).not_to include("Retracted salary numbers")
    expect(CoPlan::PlanEvent.find_by(event_type: "comment_deleted").metadata).to eq("comment_id" => deleted.id, "thread_id" => thread.id)
  end
end
