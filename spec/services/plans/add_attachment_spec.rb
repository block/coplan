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

  it "reuses identical content without another blob, storage upload, attachment, or event" do
    original = described_class.call(plan: plan, file: uploaded_file, user: user)
    expect(original).not_to be_reused
    expect(ActiveStorage::Blob).not_to receive(:create_and_upload!)

    expect {
      repeated = described_class.call(plan: plan, file: uploaded_file, user: user)
      expect(repeated).to be_success
      expect(repeated).to be_reused
      expect(repeated.attachment).to eq(original.attachment)
    }.not_to change(ActiveStorage::Blob, :count)
    expect(plan.attachments.count).to eq(1)
    expect(plan.plan_events.where(event_type: "attachment_added").count).to eq(1)
  end

  it "reuses renamed content while keeping the original filename and uploader" do
    original = described_class.call(plan: plan, file: uploaded_file, user: user)
    renamed = Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/sample.png"),
      "image/png", original_filename: "renamed.png")
    result = described_class.call(plan: plan, file: renamed, user: create(:coplan_user))

    expect(result).to be_reused
    expect(result.attachment).to eq(original.attachment)
    expect(result.attachment.blob.filename.to_s).to eq("sample.png")
    expect(result.attachment.blob.metadata["uploaded_by_id"]).to eq(user.id)
  end

  it "stores different contents separately even with the same filename" do
    original = described_class.call(plan: plan, file: uploaded_file("sample.txt", "text/plain"), user: user)
    changed = uploaded_file("sample.txt", "text/plain")
    changed.tempfile.rewind
    changed.tempfile.truncate(0)
    changed.tempfile.write("x" * original.attachment.blob.byte_size)
    changed.tempfile.rewind
    result = described_class.call(plan: plan, file: changed, user: user)

    expect(result).to be_success
    expect(result).not_to be_reused
    expect(result.attachment.blob_id).not_to eq(original.attachment.blob_id)
    expect(plan.attachments.count).to eq(2)
  end

  it "keeps identical files on different plans independent" do
    original = described_class.call(plan: plan, file: uploaded_file, user: user)
    other_plan = create(:plan, created_by_user: user)
    result = described_class.call(plan: other_plan, file: uploaded_file, user: user)

    expect(result).not_to be_reused
    expect(result.attachment.blob_id).not_to eq(original.attachment.blob_id)
    expect(other_plan.attachments.count).to eq(1)
  end

  it "compares checksums case-sensitively even on a case-insensitive database" do
    original = described_class.call(plan: plan, file: uploaded_file, user: user)
    original.attachment.blob.update_columns(checksum: original.attachment.blob.checksum.swapcase)
    result = described_class.call(plan: plan, file: uploaded_file, user: user)

    expect(result).not_to be_reused
    expect(plan.attachments.count).to eq(2)
  end

  it "does not save unrelated pending plan changes while attaching" do
    plan.title = "An unsaved title"
    expect {
      result = described_class.call(plan: plan, file: uploaded_file, user: user)
      expect(result.error).to include("Save plan changes")
    }.not_to change(ActiveStorage::Blob, :count)
    expect(plan.reload.title).not_to eq("An unsaved title")
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
