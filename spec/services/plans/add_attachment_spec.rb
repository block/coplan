require "rails_helper"

RSpec.describe CoPlan::Plans::AddAttachment do
  let(:user) { create(:coplan_user) }
  let(:plan) { create(:plan, created_by_user: user) }

  def uploaded_file(fixture = "sample.png", content_type = "image/png")
    Rack::Test::UploadedFile.new(
      Rails.root.join("spec/fixtures/files", fixture), content_type
    )
  end

  it "attaches the file, stamps the uploader, and logs an event" do
    result = described_class.call(plan: plan, file: uploaded_file, user: user)

    expect(result).to be_success
    expect(result.attachment).to be_persisted
    expect(result.attachment.blob.filename.to_s).to eq("sample.png")
    expect(result.attachment.blob.metadata["uploaded_by_id"]).to eq(user.id)
    expect(result.attachment.blob.metadata["uploaded_by_name"]).to eq(user.name)

    event = plan.plan_events.find_by(event_type: "attachment_added")
    expect(event.after_value).to eq("sample.png")
    expect(event.actor_type).to eq("human")
  end

  it "passes actor_type/actor_id overrides through to the event" do
    result = described_class.call(
      plan: plan, file: uploaded_file, user: user,
      actor_type: "local_agent", actor_id: "token-123"
    )

    expect(result).to be_success
    event = plan.plan_events.find_by(event_type: "attachment_added")
    expect(event.actor_type).to eq("local_agent")
    expect(event.actor_id).to eq("token-123")
  end

  it "rejects a missing file" do
    result = described_class.call(plan: plan, file: nil, user: user)
    expect(result.error).to include("file is required")
  end

  it "rejects a disallowed declared content type before creating a blob" do
    expect {
      result = described_class.call(plan: plan, file: uploaded_file("sample.html", "text/html"), user: user)
      expect(result.error).to include("text/html is not allowed")
    }.not_to change(ActiveStorage::Blob, :count)
  end

  it "rejects an oversized file before creating a blob" do
    stub_const("CoPlan::Plan::ATTACHMENT_MAX_BYTES", 4)

    expect {
      result = described_class.call(plan: plan, file: uploaded_file, user: user)
      expect(result.error).to include("too large")
    }.not_to change(ActiveStorage::Blob, :count)
  end

  it "purges the blob when content sniffing reclassifies the file to a disallowed type" do
    result = described_class.call(plan: plan, file: uploaded_file("sample.html", "text/plain"), user: user)

    expect(result.error).to include("disallowed content type")
    expect(ActiveStorage::Blob.count).to eq(0)
    expect(plan.attachments.count).to eq(0)
    expect(plan.plan_events.where(event_type: "attachment_added")).to be_empty
    # The plan instance is left clean for further use.
    expect(plan.errors).to be_empty
    expect(plan.attachment_changes).to be_empty
  end
end
