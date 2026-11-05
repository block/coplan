require "rails_helper"

RSpec.describe CoPlan::PlanVersion, type: :model do
  it "is valid with valid attributes" do
    plan = create(:plan)
    version = plan.current_plan_version
    expect(version).to be_valid
  end

  it "computes sha256 automatically" do
    version = build(:plan_version, content_markdown: "test content", content_sha256: nil)
    expect(version).to be_valid
    expect(version.content_sha256).to eq(Digest::SHA256.hexdigest("test content"))
  end

  it "protects persisted body, hash and version identity while allowing provenance backfills" do
    version = create(:plan).current_plan_version
    { content_markdown: "changed", content_sha256: "bad", revision: 9, plan_id: SecureRandom.uuid, id: SecureRandom.uuid }.each do |field, value|
      expect { version.update_columns(field => value) }.to raise_error(ActiveRecord::ActiveRecordError)
    end
    expect { version.update!(content_markdown: "changed") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    version.reload.update!(writing_provenance: { "backfill" => true })
    expect(version.reload.writing_provenance).to eq("backfill" => true)
  end

  it "rejects a supplied hash that differs from the stored bytes and fails closed on corrupt legacy data" do
    expect(build(:plan_version, content_markdown: "body", content_sha256: "wrong")).not_to be_valid
    version = create(:plan).current_plan_version
    CoPlan::PlanVersion.where(id: version.id).update_all(content_markdown: "tampered")
    expect { version.reload.verified_content! }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "validates revision uniqueness per plan" do
    plan = create(:plan)
    existing_version = plan.current_plan_version
    version = build(:plan_version, plan: plan, revision: existing_version.revision)
    expect(version).not_to be_valid
    expect(version.errors[:revision]).to include("has already been taken")
  end

  it "validates actor_type inclusion" do
    version = build(:plan_version, actor_type: "robot")
    expect(version).not_to be_valid
  end
end
