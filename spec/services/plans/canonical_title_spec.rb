require "rails_helper"

RSpec.describe "Canonical document titles" do
  let(:user) { create(:coplan_user) }
  let(:plan) { CoPlan::Plans::Create.call(user: user, content: "# Original\n\nBody", actor_type: "local_agent") }

  def replace(content, **options)
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: content, base_revision: plan.current_revision,
      actor_type: "local_agent", actor_id: user.id, **options)
  end

  it "creates from content without metadata and ignores conflicting metadata when content has a title" do
    expect(plan.title).to eq("Original")
    other = CoPlan::Plans::Create.call(user: user, title: "Ignored", content: "# Actual\n\nBody")
    expect(other.title).to eq("Actual")
  end

  it "repairs titleless replacements and records replayable operations and hashes" do
    before = plan.current_content
    result = replace("Updated body")
    version = result[:version]
    expect(plan.reload.current_content).to eq("# Original\n\nUpdated body")
    expect(version.content_sha256).to eq(Digest::SHA256.hexdigest(plan.current_content))
    replayed = CoPlan::Plans::ApplyOperations.call(content: before, operations: version.operations_json.map { |op| op.merge("_pre_resolved_ranges" => [ op.fetch("resolved_range") ]) })
    expect(replayed[:content]).to eq(plan.current_content)
  end

  it "autosaves renamed headings without changing the URL until Done, even with no new text" do
    original_path = plan.url_path
    3.times do |i|
      CoPlan::Plans::SaveHumanDraft.call(plan: plan, content: "# Draft #{i}\n\nBody", base_revision: plan.current_revision, actor: user)
      expect(plan.reload.title).to eq("Draft #{i}")
      expect(plan.url_path).to eq(original_path)
    end
    expect(CoPlan::UrlAlias.exact.where(path: original_path)).to be_empty
    revision = plan.current_revision
    CoPlan::Plans::SaveHumanDraft.call(plan: plan, content: plan.current_content, base_revision: revision, actor: user, finalize: true)
    expect(plan.reload.current_revision).to eq(revision)
    expect(plan.url_path).not_to eq(original_path)
    expect(CoPlan::UrlAlias.rewrite(original_path)).to eq(plan.url_path)
  end

  it "retains an empty human title during autosave and fills it on Done" do
    CoPlan::Plans::SaveHumanDraft.call(plan: plan, content: "#\n\nBody", base_revision: plan.current_revision, actor: user)
    expect(plan.reload.current_content).to eq("#\n\nBody")
    CoPlan::Plans::SaveHumanDraft.call(plan: plan, content: plan.current_content, base_revision: plan.current_revision, actor: user, finalize: true)
    expect(plan.reload.current_content).to eq("# Untitled\n\nBody")
  end

  it "finalizes agent renames and keeps old aliases direct across repeated renames" do
    original_path = plan.url_path
    7.times { |i| replace("# Revision #{i}\n\nBody") }
    expect(CoPlan::UrlAlias.rewrite(original_path)).to eq(plan.reload.url_path)
    expect(CoPlan::UrlAlias.find_by!(path: original_path).target_path).to eq(plan.url_path)
  end

  it "does not churn a collision suffix when Done is repeated" do
    plan
    other = CoPlan::Plans::Create.call(user: user, content: "# Original\n\nOther")
    path = other.url_path
    expect(other.slug_suffix).to be_present
    3.times do
      CoPlan::Plans::SaveHumanDraft.call(plan: other, content: other.current_content,
        base_revision: other.current_revision, actor: user, finalize: true)
    end
    expect(other.reload.url_path).to eq(path)
    expect(CoPlan::UrlAlias.find_by(path: path)).to be_nil
  end

  it "does not overwrite intervening changes when Done is stale" do
    base = plan.current_revision
    replace("# Agent title\n\nBody")
    expect {
      CoPlan::Plans::SaveHumanDraft.call(plan: plan, content: "# Human title\n\nBody", base_revision: base, actor: user, finalize: true)
    }.to raise_error(CoPlan::Plans::MergeText::Conflict)
    expect(plan.reload.title).to eq("Agent title")
  end
end
