require "rails_helper"

RSpec.describe CoPlan::Plan, type: :model do
  it "is valid with valid attributes" do
    plan = create(:plan)
    expect(plan).to be_valid
  end

  it "requires title" do
    plan = build(:plan, title: nil)
    expect(plan).not_to be_valid
    expect(plan.errors[:title]).to include("can't be blank")
  end

  it "validates status inclusion" do
    plan = create(:plan)
    plan.status = "invalid"
    expect(plan).not_to be_valid
  end

  it "defaults status to brainstorm" do
    plan = CoPlan::Plan.new
    expect(plan.status).to eq("brainstorm")
  end

  it "returns current content from version" do
    plan = create(:plan)
    expect(plan.current_content).to include("Plan Content")
  end

  it "returns id for to_param" do
    plan = create(:plan)
    expect(plan.to_param).to eq(plan.id)
  end

  describe "search_text denormalization (COPLAN-21)" do
    it "is populated from title, author name, tag names, and stripped current content" do
      author = create(:coplan_user, name: "Carmen Author")
      plan = create(:plan,
        :considering,
        created_by_user: author,
        title: "Quarterly Strategy Document")
      plan.tags = [CoPlan::Tag.find_or_create_by!(name: "strategy")]
      plan.reload

      expect(plan.search_text).to include("Quarterly Strategy Document")
      expect(plan.search_text).to include("Carmen Author")
      expect(plan.search_text).to include("strategy")
      expect(plan.search_text).to include("Plan Content")
    end

    it "refreshes when the title changes" do
      plan = create(:plan, :considering, title: "Original Title")
      plan.update!(title: "Renamed Plan")
      expect(plan.reload.search_text).to include("Renamed Plan")
      expect(plan.search_text).not_to include("Original Title")
    end

    it "refreshes when a tag is added" do
      plan = create(:plan, :considering)
      expect(plan.search_text).not_to include("infrastructure")
      plan.tags = [CoPlan::Tag.find_or_create_by!(name: "infrastructure")]
      expect(plan.reload.search_text).to include("infrastructure")
    end

    it "refreshes every associated plan when a tag is renamed" do
      tag = CoPlan::Tag.find_or_create_by!(name: "old-name")
      plan = create(:plan, :considering)
      plan.tags = [tag]
      expect(plan.reload.search_text).to include("old-name")

      tag.update!(name: "new-name")

      expect(plan.reload.search_text).to include("new-name")
      expect(plan.search_text).not_to include("old-name")
    end

    it "does not crash when the PlanTag callback fires after the parent plan is destroyed" do
      # Simulates the after_commit on PlanTag running when its parent Plan
      # row is already gone — this happens during dependent: :destroy cascade.
      plan = create(:plan, :considering)
      plan.tags = [CoPlan::Tag.find_or_create_by!(name: "platform")]
      plan_tag = plan.plan_tags.first
      allow(plan_tag).to receive(:plan).and_return(plan)
      allow(plan).to receive(:destroyed?).and_return(true)
      expect { plan_tag.send(:refresh_plan_search_text) }.not_to raise_error
    end

    it "refreshes when current_plan_version_id changes (new content version)" do
      plan = create(:plan, :considering)
      new_version = create(:plan_version,
        plan: plan,
        revision: plan.current_revision + 1,
        content_markdown: "# Brand new content with marker_word_xyz",
        actor_id: plan.created_by_user_id)
      plan.update!(current_plan_version: new_version, current_revision: new_version.revision)
      expect(plan.reload.search_text).to include("marker_word_xyz")
    end
  end

  describe ".search (COPLAN-21)" do
    # InnoDB FULLTEXT writes are not visible to MATCH … AGAINST inside the
    # same transaction (the FTS index maintains its own visibility tracking).
    # The transactional-fixture wrapping would hide every row we insert, so
    # these examples manage cleanup manually.
    self.use_transactional_tests = false

    after do
      ActiveRecord::Base.connection.execute("SET FOREIGN_KEY_CHECKS = 0")
      %w[coplan_plan_tags coplan_tags coplan_plan_versions coplan_plans
         coplan_search_queries coplan_users].each do |t|
        ActiveRecord::Base.connection.execute("TRUNCATE TABLE #{t}")
      end
      ActiveRecord::Base.connection.execute("SET FOREIGN_KEY_CHECKS = 1")
    end

    let!(:author) { create(:coplan_user, name: "Tessa Engineer") }
    let!(:other_author) { create(:coplan_user) }

    let!(:published) do
      create(:plan, :considering, created_by_user: author, title: "Sitewide Search Modal")
    end

    let!(:other_published) do
      create(:plan, :considering, created_by_user: other_author, title: "Sitewide Reporting Dashboard")
    end

    let!(:brainstorm) do
      create(:plan, :brainstorm, created_by_user: author, title: "Sitewide Brainstorm Notes")
    end

    it "matches whole words in the title" do
      results = CoPlan::Plan.search("modal", user: author).to_a
      expect(results).to include(published)
      expect(results).not_to include(other_published)
    end

    it "supports prefix matching for search-as-you-type" do
      results = CoPlan::Plan.search("repor", user: author).to_a
      expect(results).to include(other_published)
    end

    it "hides brainstorm plans from other users" do
      results = CoPlan::Plan.search("sitewide", user: other_author).to_a
      expect(results).to include(published, other_published)
      expect(results).not_to include(brainstorm)
    end

    it "includes the author's own brainstorm plans" do
      results = CoPlan::Plan.search("sitewide", user: author).to_a
      expect(results).to include(brainstorm)
    end

    it "returns no results for a blank query" do
      expect(CoPlan::Plan.search("", user: author).to_a).to eq([])
    end

    it "ignores FULLTEXT boolean operators in user input" do
      expect {
        CoPlan::Plan.search("+modal -reporting", user: author).to_a
      }.not_to raise_error
    end
  end
end
