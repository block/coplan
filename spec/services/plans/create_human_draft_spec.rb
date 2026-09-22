require "rails_helper"

RSpec.describe CoPlan::Plans::CreateHumanDraft do
  let(:user) { create(:coplan_user) }
  let(:key) { SecureRandom.uuid }

  def create_draft(user: self.user, creation_key: key, content: "First draft")
    described_class.call(user: user, creation_key: creation_key, title: "New plan", content: content, tags: "kept")
  end

  it "returns one document for retries and does not overwrite subsequent edits" do
    first = create_draft
    CoPlan::Plans::ReplaceContent.call(plan: first, new_content: "Later edit", base_revision: 1, actor_type: "human", actor_id: user.id)
    expect { expect(create_draft(creation_key: key.upcase).id).to eq(first.id) }.not_to change(CoPlan::Plan, :count)
    expect(first.reload.current_content).to eq("Later edit")
    expect(first.current_revision).to eq(2)
    expect(first.tag_names).to eq([ "kept" ])
  end

  it "scopes keys to the author" do
    first = create_draft
    other = create(:coplan_user)
    expect(create_draft(user: other).id).not_to eq(first.id)
  end

  it "allows a corrected retry after validation fails" do
    expect { create_draft(content: "") }.to raise_error(ActiveRecord::RecordInvalid)
    expect(create_draft).to be_persisted
  end

  it "rejects malformed keys" do
    [ "", "not-a-uuid", [] ].each do |invalid|
      expect { create_draft(creation_key: invalid) }.to raise_error(described_class::InvalidKey)
    end
  end
end
