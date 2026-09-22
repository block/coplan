require "rails_helper"

RSpec.describe CoPlan::CommentsHelper, type: :helper do
  describe "#comment_author_name" do
    it "renders 'Agent (via User)' for a local_agent comment" do
      user = create(:coplan_user, name: "Alice")
      comment = create(:comment, author_type: "local_agent", agent_name: "Amp", author_id: user.id)

      expect(helper.comment_author_name(comment)).to eq("Amp (via Alice)")
    end

    it "renders just the user name for a human comment" do
      user = create(:coplan_user, name: "Bob")
      comment = create(:comment, author_type: "human", author_id: user.id)

      expect(helper.comment_author_name(comment)).to eq("Bob")
    end
  end

  describe "#comment_agent_owner_label" do
    it "identifies the user whose agent posted the comment" do
      user = create(:coplan_user, name: "Hampton Lintorn-Catlin")
      comment = create(:comment, author_type: "local_agent", agent_name: "Amp", author_id: user.id)

      expect(helper.comment_agent_owner_label(comment)).to eq("Hampton's agent")
    end

    it "labels an agent without a local owner as an AI agent" do
      comment = create(:comment, author_type: "cloud_persona", agent_name: "Claude")

      expect(helper.comment_agent_owner_label(comment)).to eq("AI agent")
    end
  end

  describe "#comment_agent_icon_source" do
    it "uses the registered harness's built-in company icon" do
      harness = create(:agent_harness, key: "amp", display_name: "Amp")
      comment = create(:comment, author_type: "local_agent", agent_name: "Amp", agent_harness: harness)

      expect(helper.comment_agent_icon_source(comment)).to include("coplan/agent-amp")
    end

    it "prefers an admin-configured icon URL" do
      harness = create(:agent_harness, icon_url: "https://example.com/custom-agent.svg")
      comment = create(:comment, author_type: "cloud_persona", agent_name: "Custom", agent_harness: harness)

      expect(helper.comment_agent_icon_source(comment)).to eq("https://example.com/custom-agent.svg")
    end
  end
end
