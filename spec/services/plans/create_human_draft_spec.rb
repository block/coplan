require "rails_helper"

RSpec.describe CoPlan::Plans::CreateHumanDraft do
  # These examples configure their own catalog. Seeded reference data must
  # not determine their fixtures or the order in which they pass.
  before { CoPlan::PlanType.delete_all }

  let(:user) { create(:coplan_user) }
  let(:key) { SecureRandom.uuid }

  it "names the author of initially typed content in the retained sources" do
    draft = described_class.call(user: user, creation_key: key, title: "Typed draft", content: "Typed words", tags: "",
      input_sources: { "runs" => [ [ 11, "human" ] ] })
    expect(draft.current_plan_version.actor_id).to eq(user.id)
    contributor = draft.writing_provenance_summary.fetch("contributors").find { |source| source["kind"] == "human" }
    expect(contributor).to include("user_id" => user.id, "user_name" => user.name, "share" => 1.0)
    source = CoPlan::Plans::WritingProvenance.rendered_sources(draft.current_plan_version).fetch(:sources).values.first
    expect(source).to include("user_name" => user.name, "origin_revision" => 1)
  end

  def create_draft(user: self.user, creation_key: key, content: "First draft")
    described_class.call(user: user, creation_key: creation_key, title: "New plan", content: content, tags: "kept")
  end

  it "returns one document for retries and does not overwrite subsequent edits" do
    first = create_draft
    expect(first).to be_published
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

  it "preserves an existing private plan's visibility on a retried save" do
    first = create_draft
    first.update!(visibility: "draft")

    expect(create_draft.id).to eq(first.id)
    expect(first.reload).to be_draft
  end

  it "creates a typed shared plan once with an alias from its titled root path" do
    folder = create(:folder, created_by_user: user)
    type = create(:plan_type, name: "Research", default_tags: [ "research" ])
    aliases_before = CoPlan::UrlAlias.count

    first = described_class.call(user: user, creation_key: key, title: "Latency findings",
      content: "Measured latency.", tags: "metrics", plan_type: type, folder: folder)
    retried = described_class.call(user: user, creation_key: key, title: "Different title",
      content: "Different content", tags: "", plan_type: type, folder: folder)

    expect(retried.id).to eq(first.id)
    expect(first.reload.title).to eq("Latency findings")
    expect(first.slug).to eq("latency-findings")
    expect(first.placement.folder).to eq(folder)
    expect(first.tag_names).to contain_exactly("research", "metrics")
    expect(CoPlan::UrlAlias.count).to eq(aliases_before + 1)
    expect(CoPlan::UrlAlias.last).to have_attributes(
      path: "#{user.library.handle}/latency-findings", target_path: first.url_path)
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
