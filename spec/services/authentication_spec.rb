require "rails_helper"

RSpec.describe CoPlan::Authentication do
  describe ".provision_user!" do
    it "creates a user from host-supplied attributes" do
      user = described_class.provision_user!(external_id: "new@example.com", name: "New Person", username: "newbie")
      expect(user).to be_persisted
      expect(user.username).to eq("newbie")
    end

    it "syncs changed attributes on an existing user" do
      existing = create(:coplan_user, external_id: "sync@example.com", name: "Old Name")
      user = described_class.provision_user!(external_id: "sync@example.com", name: "New Name")
      expect(user.id).to eq(existing.id)
      expect(user.reload.name).to eq("New Name")
    end

    it "drops a username already held by a different account instead of failing the request" do
      create(:coplan_user, username: "hampton")

      user = described_class.provision_user!(external_id: "second@example.com", name: "Second Hampton", username: "hampton")
      expect(user).to be_persisted
      expect(user.username).to be_nil
    end

    it "keeps an existing user's own username when the host re-sends it" do
      existing = create(:coplan_user, external_id: "keep@example.com", username: "keeper")
      user = described_class.provision_user!(external_id: "keep@example.com", name: "Keeper", username: "keeper")
      expect(user.id).to eq(existing.id)
      expect(user.reload.username).to eq("keeper")
    end

    it "keeps the current username when the host sends one that now collides" do
      create(:coplan_user, username: "wanted")
      existing = create(:coplan_user, external_id: "mine@example.com", username: "mine")

      user = described_class.provision_user!(external_id: "mine@example.com", name: "Me", username: "wanted")
      expect(user.id).to eq(existing.id)
      expect(user.reload.username).to eq("mine")
    end
  end
end
