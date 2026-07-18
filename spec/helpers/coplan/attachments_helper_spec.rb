require "rails_helper"

RSpec.describe CoPlan::AttachmentsHelper, type: :helper do
  def build_blob(filename:, content_type:, metadata: {})
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("data"),
      filename: filename,
      content_type: content_type,
      metadata: metadata,
      identify: false
    )
  end

  describe "#attachment_uploader_name" do
    it "returns the name stamped at upload time" do
      blob = build_blob(filename: "a.txt", content_type: "text/plain",
        metadata: { "uploaded_by_id" => "u1", "uploaded_by_name" => "Ada" })
      expect(helper.attachment_uploader_name(blob)).to eq("Ada")
    end

    it "returns nil when no uploader was recorded" do
      blob = build_blob(filename: "a.txt", content_type: "text/plain")
      expect(helper.attachment_uploader_name(blob)).to be_nil
    end
  end

  describe "#attachment_markdown_snippet" do
    it "emits image markdown for images" do
      blob = build_blob(filename: "pic.png", content_type: "image/png")
      expect(helper.attachment_markdown_snippet(blob, "/blobs/pic.png")).to eq("![pic.png](/blobs/pic.png)")
    end

    it "emits a plain link for non-images" do
      blob = build_blob(filename: "doc.pdf", content_type: "application/pdf")
      expect(helper.attachment_markdown_snippet(blob, "/blobs/doc.pdf")).to eq("[doc.pdf](/blobs/doc.pdf)")
    end

    it "escapes markdown metacharacters in the filename" do
      blob = build_blob(filename: "x](evil).png", content_type: "image/png")
      expect(helper.attachment_markdown_snippet(blob, "/blobs/pic.png"))
        .to eq("![x\\](evil).png](/blobs/pic.png)")
    end

    it "percent-encodes URL characters that would terminate the link" do
      blob = build_blob(filename: "report (final).pdf", content_type: "application/pdf")
      expect(helper.attachment_markdown_snippet(blob, "/blobs/report (final).pdf"))
        .to eq("[report (final).pdf](/blobs/report%20%28final%29.pdf)")
    end
  end

  describe "#attachment_icon" do
    it "maps content types to icons with a generic fallback" do
      expect(helper.attachment_icon("application/pdf")).to eq("📕")
      expect(helper.attachment_icon("application/zip")).to eq("🗜️")
      expect(helper.attachment_icon("text/csv")).to eq("🗒️")
      expect(helper.attachment_icon("text/plain")).to eq("📄")
    end
  end
end
