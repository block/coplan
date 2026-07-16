require "rails_helper"

RSpec.describe "Api::V1::Attachments", type: :request do
  let(:user) { create(:coplan_user) }
  let(:token) { create(:api_token, user: user, raw_token: "test-token-attach") }
  let(:headers) { { "Authorization" => "Bearer test-token-attach" } }
  let(:plan) { create(:plan, :considering, created_by_user: user) }

  let(:other_user) { create(:coplan_user) }
  let(:other_token) { create(:api_token, user: other_user, raw_token: "test-token-other") }
  let(:other_headers) { { "Authorization" => "Bearer test-token-other" } }

  before { token }

  def upload_file(fixture = "sample.png", content_type = "image/png", headers: self.headers, plan: self.plan)
    post api_v1_plan_attachments_path(plan),
      params: { file: fixture_file_upload(fixture, content_type) },
      headers: headers
  end

  describe "POST /api/v1/plans/:plan_id/attachments" do
    it "uploads a file and returns attachment JSON with URLs and markdown snippet" do
      expect { upload_file }.to change { plan.attachments_attachments.count }.by(1)

      expect(response).to have_http_status(:created)
      data = JSON.parse(response.body)
      expect(data["filename"]).to eq("sample.png")
      expect(data["content_type"]).to eq("image/png")
      expect(data["byte_size"]).to be > 0
      expect(data["uploaded_by"]).to eq(user.name)
      expect(data["url"]).to include("/rails/active_storage/blobs/")
      expect(data["download_url"]).to include("disposition=attachment")
      expect(data["markdown"]).to eq("![sample.png](#{data["url"]})")
    end

    it "stamps the uploader into the blob metadata" do
      upload_file
      blob = plan.attachments.first.blob
      expect(blob.metadata["uploaded_by_id"]).to eq(user.id)
      expect(blob.metadata["uploaded_by_name"]).to eq(user.name)
    end

    it "logs an attachment_added event" do
      expect { upload_file }.to change { plan.plan_events.where(event_type: "attachment_added").count }.by(1)

      event = plan.plan_events.find_by(event_type: "attachment_added")
      expect(event.after_value).to eq("sample.png")
      expect(event.actor_type).to eq("local_agent")
      expect(event.actor_id).to eq(token.id)
      expect(event.metadata["content_type"]).to eq("image/png")
    end

    it "rejects files over the size limit without creating a blob" do
      stub_const("CoPlan::Plan::ATTACHMENT_MAX_BYTES", 4)

      expect { upload_file }.not_to change(ActiveStorage::Blob, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("too large")
    end

    it "rejects disallowed content types without creating a blob" do
      expect { upload_file("sample.html", "text/html") }.not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("text/html is not allowed")
      expect(plan.attachments.count).to eq(0)
    end

    it "rejects html content spoofed with an allowed declared type (sniffing backstop)" do
      upload_file("sample.html", "text/plain")

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("disallowed content type")
      expect(plan.attachments.count).to eq(0)
      # The pre-created blob must be purged, not orphaned.
      expect(ActiveStorage::Blob.count).to eq(0)
    end

    it "returns 422 when no file is provided" do
      post api_v1_plan_attachments_path(plan), headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to include("file is required")
    end

    it "forbids non-authors" do
      other_token
      upload_file(headers: other_headers)
      expect(response).to have_http_status(:forbidden)
      expect(plan.attachments.count).to eq(0)
    end

    it "requires authentication" do
      post api_v1_plan_attachments_path(plan), params: { file: fixture_file_upload("sample.png", "image/png") }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 for unknown plan" do
      post api_v1_plan_attachments_path("nonexistent-id"),
        params: { file: fixture_file_upload("sample.png", "image/png") },
        headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/plans/:plan_id/attachments" do
    it "lists attachments with download URLs" do
      upload_file
      upload_file("sample.txt", "text/plain")

      get api_v1_plan_attachments_path(plan), headers: headers
      expect(response).to have_http_status(:ok)

      data = JSON.parse(response.body)
      expect(data.length).to eq(2)
      expect(data.map { |a| a["filename"] }).to contain_exactly("sample.png", "sample.txt")
      data.each do |a|
        expect(a["url"]).to include("/rails/active_storage/blobs/")
        expect(a["download_url"]).to include("disposition=attachment")
        expect(a["uploaded_by"]).to eq(user.name)
      end
    end

    it "allows any authenticated viewer to list" do
      upload_file
      other_token

      get api_v1_plan_attachments_path(plan), headers: other_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).length).to eq(1)
    end

    it "requires authentication" do
      get api_v1_plan_attachments_path(plan)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE /api/v1/plans/:plan_id/attachments/:id" do
    it "deletes an attachment and logs an event" do
      upload_file
      attachment = plan.attachments_attachments.first

      expect {
        delete api_v1_plan_attachment_path(plan, attachment.id), headers: headers
      }.to change { plan.attachments_attachments.count }.by(-1)

      expect(response).to have_http_status(:no_content)
      event = plan.plan_events.find_by(event_type: "attachment_removed")
      expect(event.before_value).to eq("sample.png")
      expect(event.actor_type).to eq("local_agent")
    end

    it "forbids non-authors" do
      upload_file
      attachment = plan.attachments_attachments.first
      other_token

      delete api_v1_plan_attachment_path(plan, attachment.id), headers: other_headers
      expect(response).to have_http_status(:forbidden)
      expect(plan.attachments_attachments.count).to eq(1)
    end

    it "returns not found for unknown attachment" do
      delete api_v1_plan_attachment_path(plan, 999_999), headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
