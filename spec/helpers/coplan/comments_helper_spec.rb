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
end
