require "rails_helper"
require CoPlan::Engine.root.join("db/migrate/20261105220000_unify_document_titles.rb")

RSpec.describe CoPlan::MigrationSupport::BackfillDocumentTitles do
  def legacy_plan(content)
    plan = create(:plan, title: "Metadata title")
    set_version_fixture(plan.current_plan_version, content_markdown: content)
    plan.reload
  end

  it "repairs missing and mismatching headings without changing history or URLs, and can rerun" do
    plans = [ legacy_plan("Body"), legacy_plan("# Old\n\nBody"), legacy_plan("# Metadata title\n\nBody") ]
    before = plans.map { |p| [ p.current_plan_version, p.current_content, p.url_path ] }
    described_class.call
    plans.each_with_index do |plan, i|
      old, content, path = before[i]
      expect(plan.reload.current_content).to eq("# Metadata title\n\nBody")
      expect(old.reload.content_markdown).to eq(content)
      expect(plan.url_path).to eq(path)
      expect(plan.current_revision).to eq(i == 2 ? 1 : 2)
      expect(plan.current_plan_version.actor_type).to eq("system") unless i == 2
    end
    expect { described_class.call }.not_to change(CoPlan::PlanVersion, :count)
  end

  it "gives a legacy plan without a current version its first titled content" do
    plan = CoPlan::Plan.create!(title: "Legacy skeleton", created_by_user: create(:coplan_user))
    path = plan.url_path
    described_class.call
    expect(plan.reload.current_content).to eq("# Legacy skeleton\n\n")
    expect(plan.current_revision).to eq(1)
    expect(plan.current_plan_version.actor_type).to eq("system")
    expect(plan.url_path).to eq(path)
    expect { described_class.call }.not_to change(CoPlan::PlanVersion, :count)
  end

  it "refreshes schema cached before the review policy migrations" do
    plan = legacy_plan("Body")
    columns = CoPlan::Plan.columns_hash
    schema_cache = CoPlan::Plan.connection_pool.schema_cache
    allow(schema_cache).to receive(:columns_hash).and_call_original
    allow(schema_cache).to receive(:columns_hash).with("coplan_plans")
      .and_return(columns.except("reset_reviews_on_change"), columns)
    CoPlan::Plan.reset_column_information
    # Production's writing-provenance initializer loads this before db:migrate.
    expect(CoPlan::Plan.column_names).not_to include("reset_reviews_on_change")

    described_class.call

    expect(plan.reload.current_content).to eq("# Metadata title\n\nBody")
    expect(plan.reset_reviews_on_change).to be(true)
  ensure
    CoPlan::Plan.reset_column_information
  end

  it "respects leases and resumes after the lease is released" do
    plan = legacy_plan("Body")
    CoPlan::EditLease.acquire!(plan: plan, holder_type: "local_agent", holder_id: plan.created_by_user_id, lease_token: "migration-test")
    expect { described_class.call }.to raise_error(CoPlan::EditLease::Conflict)
    expect(plan.reload.current_content).to eq("Body")
    plan.edit_lease.destroy!
    described_class.call
    expect(plan.reload.current_content).to eq("# Metadata title\n\nBody")
  end

  it "adds headings to custom templates without replacing their bodies" do
    type = create(:plan_type, template_content: "## Custom section\n\nInstructions")
    described_class.call
    expect(type.reload.template_content).to eq("# Document title\n\n## Custom section\n\nInstructions")
  end
end
