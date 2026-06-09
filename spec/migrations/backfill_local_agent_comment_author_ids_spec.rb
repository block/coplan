require "rails_helper"
require CoPlan::Engine.root.join("db/migrate/20260609000000_backfill_local_agent_comment_author_ids.rb")

RSpec.describe BackfillLocalAgentCommentAuthorIds do
  subject(:migration) { described_class.new }

  before { migration.verbose = false }

  it "rewrites local_agent author_id from a token id to the token's user_id" do
    user = create(:coplan_user)
    token = create(:api_token, user: user)
    comment = create(:comment, author_type: "local_agent", agent_name: "Amp", author_id: token.id)

    migration.up

    expect(comment.reload.author_id).to eq(user.id)
    expect(comment.author).to eq(user)
  end

  it "leaves human comments untouched" do
    user = create(:coplan_user)
    comment = create(:comment, author_type: "human", author_id: user.id)

    migration.up

    expect(comment.reload.author_id).to eq(user.id)
  end

  it "leaves local_agent comments whose author_id is already a user_id untouched" do
    user = create(:coplan_user)
    comment = create(:comment, author_type: "local_agent", agent_name: "Amp", author_id: user.id)

    migration.up

    expect(comment.reload.author_id).to eq(user.id)
  end

  it "is idempotent across repeated runs" do
    user = create(:coplan_user)
    token = create(:api_token, user: user)
    comment = create(:comment, author_type: "local_agent", agent_name: "Amp", author_id: token.id)

    migration.up
    migration.up

    expect(comment.reload.author_id).to eq(user.id)
  end
end
