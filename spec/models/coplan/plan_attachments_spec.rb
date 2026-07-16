require "rails_helper"

RSpec.describe CoPlan::Plan, "attachments", type: :model do
  let(:plan) { create(:plan) }

  def attach(filename:, content_type:, io: StringIO.new("data"))
    plan.attachments.attach(io: io, filename: filename, content_type: content_type)
  end

  it "accepts allowed content types within the size limit" do
    expect(attach(filename: "notes.md", content_type: "text/markdown")).to be_truthy
    expect(plan.reload.attachments.count).to eq(1)
  end

  it "rejects disallowed content types (html)" do
    expect(attach(filename: "page.html", content_type: "text/html")).to be_nil
    expect(plan.errors[:attachments].join).to include("disallowed content type")
    expect(plan.reload.attachments.count).to eq(0)
  end

  it "rejects disallowed content types (svg)" do
    attach(filename: "image.svg", content_type: "image/svg+xml")
    expect(plan.errors[:attachments].join).to include("disallowed content type")
    expect(plan.reload.attachments.count).to eq(0)
  end

  it "rejects files over the size limit" do
    stub_const("CoPlan::Plan::ATTACHMENT_MAX_BYTES", 2)
    attach(filename: "big.txt", content_type: "text/plain")
    expect(plan.errors[:attachments].join).to include("too large")
    expect(plan.reload.attachments.count).to eq(0)
  end

  it "does not re-validate persisted attachments on unrelated saves" do
    attach(filename: "notes.txt", content_type: "text/plain")
    # Simulate a legacy attachment that would fail today's rules.
    plan.attachments.first.blob.update_columns(byte_size: described_class::ATTACHMENT_MAX_BYTES + 1)

    plan.reload
    expect(plan.update(title: "New title")).to be(true)
  end
end
