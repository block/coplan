require "rails_helper"

# Plans::Place is the single write path for filing — the web
# drag-and-drop, the row menu, and the API all trust its guard rails.
# The web move_to_folder endpoint has no authorize! of its own, so these
# rejections ARE the security boundary.
#
# A plan lives in exactly one place, so every call here is a move.
RSpec.describe CoPlan::Plans::Place do
  let(:author) { create(:coplan_user) }
  let(:other) { create(:coplan_user) }
  let(:folder) { create(:folder, created_by_user: author) }

  def place(plan:, folder:, actor:, library: nil)
    described_class.call(plan: plan, folder: folder, actor: actor, library: library)
  end

  it "files your own plan" do
    plan = create(:plan, :considering, created_by_user: author)
    result = place(plan: plan, folder: folder, actor: author)
    expect(result).to be_success
    expect(result.placement.folder).to eq(folder)
  end

  # The old model let you file someone else's published plan onto your own
  # shelf — a second placement alongside the author's. There's only one
  # place now, so doing that would take their document away from them.
  it "refuses to move someone else's plan into your library" do
    plan = create(:plan, :published, created_by_user: other)
    result = place(plan: plan, folder: folder, actor: author)
    expect(result).not_to be_success
    expect(result.error).to include("plans you wrote")
    expect(plan.reload.placement).to be_nil
  end

  it "files your own draft (your library, your secret)" do
    draft = create(:plan, :draft, created_by_user: author)
    expect(place(plan: draft, folder: folder, actor: author)).to be_success
  end

  it "refuses to write into someone else's library" do
    plan = create(:plan, :considering, created_by_user: other)
    result = described_class.call(plan: plan, folder: folder, actor: other, library: author.library)
    expect(result).not_to be_success
    expect(result.error).to include("a library you own")
  end

  it "refuses a folder from a different library" do
    plan = create(:plan, :considering, created_by_user: author)
    foreign_folder = create(:folder, created_by_user: other)
    result = described_class.call(plan: plan, folder: foreign_folder, actor: author,
      library: author.library)
    expect(result).not_to be_success
    expect(result.error).to include("different library")
  end

  it "lets you unfile your own plan even after it stopped being listable" do
    plan = create(:plan, :published, created_by_user: author)
    place(plan: plan, folder: folder, actor: author)

    plan.update_columns(visibility: "draft")

    result = place(plan: plan, folder: nil, actor: author)
    expect(result).to be_success
    expect(plan.reload.placement).to be_nil
  end

  it "moves rather than duplicating when the plan is already filed" do
    plan = create(:plan, :considering, created_by_user: author)
    second_folder = create(:folder, created_by_user: author)
    place(plan: plan, folder: folder, actor: author)
    result = place(plan: plan, folder: second_folder, actor: author)

    expect(result).to be_success
    expect(CoPlan::PlanPlacement.where(plan: plan).count).to eq(1)
    expect(result.placement.folder).to eq(second_folder)
  end

  it "cannot be filed in two places at once" do
    plan = create(:plan, :considering, created_by_user: author)
    place(plan: plan, folder: folder, actor: author)
    second = build(:plan_placement, plan: plan, folder: create(:folder, created_by_user: author))

    expect(second).not_to be_valid
    expect(second.errors[:plan_id].join).to include("already filed")
  end

  describe "library audit trail" do
    it "logs filed → moved → removed with paths and plan title" do
      plan = create(:plan, :considering, created_by_user: author, title: "Audited")
      second_folder = create(:folder, name: "Elsewhere", created_by_user: author)

      place(plan: plan, folder: folder, actor: author)
      place(plan: plan, folder: second_folder, actor: author)
      place(plan: plan, folder: nil, actor: author)

      events = author.library.library_events.order(:created_at)
      expect(events.map(&:event_type)).to eq(%w[plan_filed plan_moved plan_removed])

      moved = events.second
      expect(moved.before_value).to eq(folder.path)
      expect(moved.after_value).to eq("Elsewhere")
      expect(moved.plan_id).to eq(plan.id)
      expect(moved.metadata["plan_title"]).to eq("Audited")
      expect(moved.actor_id).to eq(author.id)
      expect(moved.actor_type).to eq("human")
    end

    it "attributes agent moves as local_agent" do
      plan = create(:plan, :considering, created_by_user: author)
      described_class.call(plan: plan, folder: folder, actor: author,
        library: author.library, actor_type: "local_agent")

      event = author.library.library_events.sole
      expect(event.actor_type).to eq("local_agent")
      expect(author.library.placements.sole.plan_id).to eq(plan.id)
      # The plan-side history event carries the same attribution.
      expect(plan.plan_events.sole.actor_type).to eq("local_agent")
    end

    it "logs nothing when a re-file is a no-op" do
      plan = create(:plan, :considering, created_by_user: author)
      place(plan: plan, folder: folder, actor: author)
      expect { place(plan: plan, folder: folder, actor: author) }
        .not_to change { author.library.library_events.count }
    end
  end
end
