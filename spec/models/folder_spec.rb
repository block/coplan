require "rails_helper"

RSpec.describe CoPlan::Folder, type: :model do
  let(:user) { create(:coplan_user) }

  describe "validations" do
    it "requires a name" do
      folder = build(:folder, name: "")
      expect(folder).not_to be_valid
      expect(folder.errors[:name]).to be_present
    end

    it "rejects slashes in names (reserved as the path separator)" do
      folder = build(:folder, name: "Team/EBT")
      expect(folder).not_to be_valid
      expect(folder.errors[:name].join).to include("cannot contain")
    end

    it "enforces unique names among siblings, case-insensitively" do
      parent = create(:folder, name: "Team EBT")
      create(:folder, name: "Q3", parent: parent)
      dup = build(:folder, name: "q3", parent: parent)
      expect(dup).not_to be_valid
      expect(dup.errors[:name]).to be_present
    end

    it "allows the same name under different parents" do
      a = create(:folder, name: "Team A")
      b = create(:folder, name: "Team B")
      create(:folder, name: "Q3", parent: a)
      expect(build(:folder, name: "Q3", parent: b)).to be_valid
    end
  end

  describe "depth limit" do
    it "allows nesting up to MAX_DEPTH levels" do
      root = create(:folder, name: "L1")
      mid = create(:folder, name: "L2", parent: root)
      expect(build(:folder, name: "L3", parent: mid)).to be_valid
    end

    it "rejects nesting beyond MAX_DEPTH levels" do
      root = create(:folder, name: "L1")
      mid = create(:folder, name: "L2", parent: root)
      leaf = create(:folder, name: "L3", parent: mid)
      too_deep = build(:folder, name: "L4", parent: leaf)
      expect(too_deep).not_to be_valid
      expect(too_deep.errors[:parent].join).to include("maximum folder depth")
    end

    it "rejects re-parenting a folder whose subtree would exceed MAX_DEPTH" do
      root = create(:folder, name: "Root")
      mid = create(:folder, name: "Mid", parent: root)
      mover = create(:folder, name: "Mover")
      create(:folder, name: "Child", parent: mover)
      mover.parent = mid
      expect(mover).not_to be_valid
      expect(mover.errors[:parent].join).to include("maximum folder depth")
    end
  end

  describe "cycle prevention" do
    it "rejects a folder as its own parent" do
      folder = create(:folder)
      folder.parent_id = folder.id
      expect(folder).not_to be_valid
      expect(folder.errors[:parent].join).to include("itself")
    end

    it "rejects a descendant as parent" do
      root = create(:folder, name: "Root")
      child = create(:folder, name: "Child", parent: root)
      root.parent = child
      expect(root).not_to be_valid
      expect(root.errors[:parent].join).to include("subfolders")
    end
  end

  describe "#ancestors / #descendants / #path / #depth" do
    let!(:root) { create(:folder, name: "Team EBT") }
    let!(:mid) { create(:folder, name: "Q3", parent: root) }
    let!(:leaf) { create(:folder, name: "Launch", parent: mid) }
    let!(:sibling) { create(:folder, name: "Q4", parent: root) }

    it "returns ancestors root-first" do
      expect(leaf.ancestors).to eq([root, mid])
      expect(root.ancestors).to eq([])
    end

    it "returns all nested descendants" do
      expect(root.descendants).to match_array([mid, leaf, sibling])
      expect(leaf.descendants).to eq([])
    end

    it "computes path and depth" do
      expect(leaf.path).to eq("Team EBT/Q3/Launch")
      expect(leaf.depth).to eq(3)
      expect(root.depth).to eq(1)
    end
  end

  describe "deletion rules" do
    it "cannot be deleted while it contains plans" do
      folder = create(:folder)
      plan = create(:plan, :considering)
      plan.update!(folder: folder)

      expect(folder.destroy).to be false
      expect(folder.errors[:base].join).to include("contains plans")
      expect(described_class.exists?(folder.id)).to be true
    end

    it "cannot be deleted while it has subfolders" do
      folder = create(:folder)
      create(:folder, parent: folder)

      expect(folder.destroy).to be false
      expect(folder.errors[:base].join).to include("subfolders")
      expect(described_class.exists?(folder.id)).to be true
    end

    it "deletes cleanly when empty" do
      folder = create(:folder)
      expect(folder.destroy).to be_truthy
      expect(described_class.exists?(folder.id)).to be false
    end
  end

  describe ".find_or_create_by_path!" do
    it "creates the full hierarchy" do
      leaf = described_class.find_or_create_by_path!("Team EBT/Q3/Launch", created_by_user: user)
      expect(leaf.name).to eq("Launch")
      expect(leaf.path).to eq("Team EBT/Q3/Launch")
      expect(leaf.created_by_user).to eq(user)
      expect(described_class.count).to eq(3)
    end

    it "reuses existing folders case-insensitively" do
      existing = create(:folder, name: "Team EBT")
      leaf = described_class.find_or_create_by_path!("team ebt/Q3", created_by_user: user)
      expect(leaf.parent).to eq(existing)
      expect(described_class.count).to eq(2)
    end

    it "returns the existing folder for an exact match" do
      leaf = described_class.find_or_create_by_path!("Team EBT/Q3", created_by_user: user)
      again = described_class.find_or_create_by_path!("Team EBT/Q3", created_by_user: user)
      expect(again).to eq(leaf)
    end

    it "returns nil for a blank path" do
      expect(described_class.find_or_create_by_path!("", created_by_user: user)).to be_nil
      expect(described_class.find_or_create_by_path!("  /  ", created_by_user: user)).to be_nil
    end

    it "raises when the path exceeds MAX_DEPTH" do
      expect {
        described_class.find_or_create_by_path!("A/B/C/D", created_by_user: user)
      }.to raise_error(ActiveRecord::RecordInvalid, /maximum folder depth/)
    end
  end
end
