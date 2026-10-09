require "rails_helper"

RSpec.describe CoPlan::Plans::SectionUpdates do
  let(:author) { create(:coplan_user) }
  let(:other_author) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: author) }
  let(:original) { "## Design\n\nOriginal design.\n\n## Rollout\n\nOriginal rollout.\n" }

  def add_version(revision, content, user = author)
    version = create(:plan_version, plan: plan, revision: revision, actor_id: user.id, content_markdown: content)
    plan.update!(current_plan_version: version, current_revision: revision)
    version
  end

  before { plan.current_plan_version.update_columns(content_markdown: original) }

  it "attributes each section to its last actual edit, even after later unrelated edits" do
    design_content = original.sub("Original design", "Revised design")
    design = add_version(2, design_content)
    rollout = add_version(3, design_content.sub("Original rollout", "Revised rollout"), other_author)
    add_version(4, rollout.content_markdown)

    updates = described_class.call(plan: plan, keys: %w[design rollout], since_revision: 1)
    expect(updates).to eq("design" => design, "rollout" => rollout)
    expect(updates["design"].actor_user).to eq(author)
    expect(updates["rollout"].actor_user).to eq(other_author)
  end

  it "attributes added and renamed sections and an edited introduction" do
    content = "New introduction.\n\n#{original.sub('## Design', '## Approach')}\n## Testing\n\nNew tests.\n"
    version = add_version(2, content)

    expect(described_class.call(plan: plan, keys: %w[__top__ approach testing], since_revision: 1))
      .to eq("__top__" => version, "approach" => version, "testing" => version)
  end

  it "walks across batches to find an older section edit" do
    content = original.sub("Original design", "Revised design")
    edited = add_version(2, content)
    (3..23).each { |revision| add_version(revision, content) }

    expect(described_class.call(plan: plan, keys: %w[design], since_revision: 1)).to eq("design" => edited)
  end

  it "does no history work when there are no section markers" do
    expect(plan).not_to receive(:plan_versions)
    expect(described_class.call(plan: plan, keys: [], since_revision: 1)).to eq({})
  end
end
