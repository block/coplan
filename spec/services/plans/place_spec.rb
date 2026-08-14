require "rails_helper"

# Plans::Place is the single write path for shelving — the web
# drag-and-drop, the row menu, and the API all trust its guard rails.
# The web move_to_folder endpoint has no authorize! of its own, so these
# rejections ARE the security boundary.
RSpec.describe CoPlan::Plans::Place do
  let(:author) { create(:coplan_user) }
  let(:other) { create(:coplan_user) }
  let(:folder) { create(:folder, created_by_user: author) }

  def place(plan:, folder:, actor:, library: nil)
    described_class.call(plan: plan, folder: folder, actor: actor, library: library || actor.library)
  end

  it "shelves your own plan" do
    plan = create(:plan, :considering, created_by_user: author)
    result = place(plan: plan, folder: folder, actor: author)
    expect(result).to be_success
    expect(result.placement.folder).to eq(folder)
  end

  it "shelves someone else's published plan (a placement, not a copy)" do
    plan = create(:plan, :published, created_by_user: other)
    result = place(plan: plan, folder: folder, actor: author)
    expect(result).to be_success
  end

  it "refuses to shelve someone else's unlisted draft, even with the URL in hand" do
    draft = create(:plan, :draft, created_by_user: other)
    result = place(plan: draft, folder: folder, actor: author)
    expect(result).not_to be_success
    expect(result.error).to include("shelved")
    expect(author.library.placements.where(plan: draft)).to be_empty
  end

  it "shelves your own draft (your library, your secret)" do
    draft = create(:plan, :draft, created_by_user: author)
    expect(place(plan: draft, folder: folder, actor: author)).to be_success
  end

  it "refuses to write into someone else's library" do
    plan = create(:plan, :considering, created_by_user: other)
    result = described_class.call(plan: plan, folder: folder, actor: other, library: author.library)
    expect(result).not_to be_success
    expect(result.error).to include("your own library")
  end

  it "refuses a folder from a different library" do
    plan = create(:plan, :considering, created_by_user: author)
    foreign_folder = create(:folder, created_by_user: other)
    result = place(plan: plan, folder: foreign_folder, actor: author)
    expect(result).not_to be_success
    expect(result.error).to include("different library")
  end

  it "always allows taking a plan off your own shelf, even if it stopped being listable" do
    plan = create(:plan, :published, created_by_user: other)
    place(plan: plan, folder: folder, actor: author)

    # Simulate the plan later becoming unlisted to the shelver.
    plan.update_columns(visibility: "draft")

    result = place(plan: plan, folder: nil, actor: author)
    expect(result).to be_success
    expect(author.library.placements.where(plan: plan)).to be_empty
  end

  it "re-files rather than duplicating when the plan is already shelved" do
    plan = create(:plan, :considering, created_by_user: author)
    second_folder = create(:folder, created_by_user: author)
    place(plan: plan, folder: folder, actor: author)
    result = place(plan: plan, folder: second_folder, actor: author)

    expect(result).to be_success
    expect(author.library.placements.where(plan: plan).count).to eq(1)
    expect(result.placement.folder).to eq(second_folder)
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

    it "logs shelving someone else's plan in the library trail but not the plan's history" do
      plan = create(:plan, :published, created_by_user: other)
      place(plan: plan, folder: folder, actor: author)

      expect(author.library.library_events.sole.event_type).to eq("plan_filed")
      expect(plan.plan_events).to be_empty
    end

    it "logs nothing when a re-file is a no-op" do
      plan = create(:plan, :considering, created_by_user: author)
      place(plan: plan, folder: folder, actor: author)
      expect { place(plan: plan, folder: folder, actor: author) }
        .not_to change { author.library.library_events.count }
    end
  end
end
