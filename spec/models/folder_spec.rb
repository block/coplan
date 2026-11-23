require "rails_helper"

RSpec.describe Coplan::Folder, type: :model do
  let(:user) { create(:coplan_user) }
  let(:library) { user.library }

  describe "validations" do
    it "requires a name" do
      folder = build(:folder, name: "", created_by_user: user)
      expect(folder).not_to be_valid
      expect(folder.errors[:name]).to be_present
    end

    it "rejects slashes in names (reserved as the path separator)" do
      folder = build(:folder, name: "Team/EBT", created_by_user: user)
      expect(folder).not_to be_valid
      expect(folder.errors[:name].join).to include("cannot contain")
    end

    it "enforces unique names among siblings, case-insensitively" do
      parent = create(:folder, name: "Team EBT", created_by_user: user)
      create(:folder, name: "Q3", parent: parent, created_by_user: user)
      dup = build(:folder, name: "q3", parent: parent, created_by_user: user)
      expect(dup).not_to be_valid
      expect(dup.errors[:name]).to be_present
    end

    it "allows the same name under different parents" do
      a = create(:folder, name: "Team A", created_by_user: user)
      b = create(:folder, name: "Team B", created_by_user: user)
      create(:folder, name: "Q3", parent: a, created_by_user: user)
      expect(build(:folder, name: "Q3", parent: b, created_by_user: user)).to be_valid
    end

    it "allows the same name in different libraries" do
      other = create(:coplan_user)
      create(:folder, name: "Infra", created_by_user: user)
      expect(build(:folder, name: "Infra", created_by_user: other)).to be_valid
    end

    it "rejects a parent from a different library" do
      other = create(:coplan_user)
      foreign_parent = create(:folder, name: "Theirs", created_by_user: other)
      folder = build(:folder, name: "Mine", parent: foreign_parent, created_by_user: user, library: library)
      expect(folder).not_to be_valid
      expect(folder.errors[:parent].join).to include("same library")
    end
  end

  describe "depth limit" do
    let!(:chain) do
      (1..described_class::MAX_DEPTH).reduce([]) do |folders, level|
        folders << create(:folder, name: "L#{level}", parent: folders.last, created_by_user: user)
      end
    end

    it "allows five folder levels" do
      expect(chain.last.depth).to eq(5)
      expect(chain.last.path).to eq("L1/L2/L3/L4/L5")
    end

    it "rejects nesting beyond MAX_DEPTH levels" do
      too_deep = build(:folder, name: "Too deep", parent: chain.last, created_by_user: user)
      expect(too_deep).not_to be_valid
      expect(too_deep.errors[:parent].join).to include("maximum folder depth")
    end

    it "allows re-parenting a subtree ending at the limit but rejects one level deeper" do
      mover = create(:folder, name: "Mover", created_by_user: user)
      child = create(:folder, name: "Child", parent: mover, created_by_user: user)

      expect(mover.update(parent: chain[-3])).to be true
      expect(child.reload.depth).to eq(5)
      expect(mover.update(parent: chain[-2])).to be false
      expect(mover.errors[:parent].join).to include("maximum folder depth")
      expect(mover.reload.parent).to eq(chain[-3])
      expect(child.reload.parent).to eq(mover)
    end

    it "finds a five-segment slug path but rejects a sixth segment" do
      expect(described_class.find_by_slug_path("l1/l2/l3/l4/l5", library: library)).to eq(chain.last)
      expect(described_class.find_by_slug_path("l1/l2/l3/l4/l5/l6", library: library)).to be_nil
    end
  end

  describe "cycle prevention" do
    it "rejects a folder as its own parent" do
      folder = create(:folder, created_by_user: user)
      folder.parent_id = folder.id
      expect(folder).not_to be_valid
      expect(folder.errors[:parent].join).to include("itself")
    end

    it "rejects a descendant as parent" do
      root = create(:folder, name: "Root", created_by_user: user)
      child = create(:folder, name: "Child", parent: root, created_by_user: user)
      root.parent = child
      expect(root).not_to be_valid
      expect(root.errors[:parent].join).to include("subfolders")
    end
  end

  describe "#ancestors / #descendants / #path / #depth" do
    let!(:root) { create(:folder, name: "Team EBT", created_by_user: user) }
    let!(:mid) { create(:folder, name: "Q3", parent: root, created_by_user: user) }
    let!(:leaf) { create(:folder, name: "Launch", parent: mid, created_by_user: user) }
    let!(:sibling) { create(:folder, name: "Q4", parent: root, created_by_user: user) }

    it "returns ancestors root-first" do
      expect(leaf.ancestors).to eq([ root, mid ])
      expect(root.ancestors).to eq([])
    end

    it "returns all nested descendants" do
      expect(root.descendants).to match_array([ mid, leaf, sibling ])
      expect(leaf.descendants).to eq([])
    end

    it "computes path and depth" do
      expect(leaf.path).to eq("Team EBT/Q3/Launch")
      expect(leaf.depth).to eq(3)
      expect(root.depth).to eq(1)
    end
  end

  describe "deletion rules" do
    it "cannot be deleted while it holds placements" do
      folder = create(:folder, created_by_user: user)
      plan = create(:plan, :considering, created_by_user: user)
      Coplan::Plans::Place.call(plan: plan, folder: folder, actor: user)

      expect(folder.destroy).to be false
      expect(folder.errors[:base].join).to include("contains plans")
      expect(described_class.exists?(folder.id)).to be true
    end

    it "cannot be deleted while it has subfolders" do
      folder = create(:folder, created_by_user: user)
      create(:folder, parent: folder, created_by_user: user)

      expect(folder.destroy).to be false
      expect(folder.errors[:base].join).to include("subfolders")
      expect(described_class.exists?(folder.id)).to be true
    end

    it "deletes cleanly when empty" do
      folder = create(:folder, created_by_user: user)
      expect(folder.destroy).to be_truthy
      expect(described_class.exists?(folder.id)).to be false
    end
  end

  describe ".find_or_create_by_path!" do
    it "creates the full hierarchy inside the given library" do
      leaf = described_class.find_or_create_by_path!("Team EBT/Q3/Launch", library: library, created_by_user: user)
      expect(leaf.name).to eq("Launch")
      expect(leaf.path).to eq("Team EBT/Q3/Launch")
      expect(leaf.created_by_user).to eq(user)
      expect(leaf.library).to eq(library)
      expect(described_class.count).to eq(3)
    end

    it "reuses existing folders case-insensitively" do
      existing = create(:folder, name: "Team EBT", created_by_user: user)
      leaf = described_class.find_or_create_by_path!("team ebt/Q3", library: library, created_by_user: user)
      expect(leaf.parent).to eq(existing)
      expect(described_class.count).to eq(2)
    end

    it "returns the existing folder for an exact match" do
      leaf = described_class.find_or_create_by_path!("Team EBT/Q3", library: library, created_by_user: user)
      again = described_class.find_or_create_by_path!("Team EBT/Q3", library: library, created_by_user: user)
      expect(again).to eq(leaf)
    end

    it "does not reuse a same-named folder from another library" do
      other = create(:coplan_user)
      create(:folder, name: "Team EBT", created_by_user: other)
      leaf = described_class.find_or_create_by_path!("Team EBT", library: library, created_by_user: user)
      expect(leaf.library).to eq(library)
      expect(described_class.count).to eq(2)
    end

    it "returns nil for a blank path" do
      expect(described_class.find_or_create_by_path!("", library: library, created_by_user: user)).to be_nil
      expect(described_class.find_or_create_by_path!("  /  ", library: library, created_by_user: user)).to be_nil
    end

    it "raises when the path exceeds MAX_DEPTH" do
      expect {
        described_class.find_or_create_by_path!("A/B/C/D/E/F", library: library, created_by_user: user)
      }.to raise_error(ActiveRecord::RecordInvalid, /maximum folder depth/)
    end

    it "creates nothing when the path is too deep (transactional)" do
      expect {
        described_class.find_or_create_by_path!("A/B/C/D/E/F", library: library, created_by_user: user)
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect(described_class.count).to eq(0)
    end
  end

  describe ".paths_by_id" do
    it "returns the full path for every folder without per-folder queries" do
      root = create(:folder, name: "Team EBT", created_by_user: user)
      sub = create(:folder, name: "Q3", parent: root, created_by_user: user)
      other = create(:folder, name: "Infra", created_by_user: user)

      paths = described_class.paths_by_id
      expect(paths).to eq(
        root.id => "Team EBT",
        sub.id => "Team EBT/Q3",
        other.id => "Infra"
      )
    end

    it "renders the full path for hierarchies deeper than MAX_DEPTH" do
      # Creation is capped at MAX_DEPTH, but data deeper than the cap (seeds,
      # imports, a future cap raise) must still render its whole path — the
      # guard in the walk is for cycles, not depth.
      parent = nil
      chain = ("A".."F").map do |name|
        folder = described_class.new(name: name, parent: parent, library: library, created_by_user: user)
        folder.save!(validate: false)
        parent = folder
      end

      expect(described_class.paths_by_id[chain.last.id]).to eq("A/B/C/D/E/F")
    end

    it "does not loop forever on cyclic bad data" do
      a = create(:folder, name: "A", created_by_user: user)
      b = create(:folder, name: "B", parent: a, created_by_user: user)
      a.update_columns(parent_id: b.id)

      paths = described_class.paths_by_id
      expect(paths[b.id]).to eq("A/B")
    end
  end
end
