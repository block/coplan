require "rails_helper"

RSpec.describe "Attachments (web)", type: :request do
  let(:author) { create(:coplan_user) }
  let(:viewer) { create(:coplan_user) }
  let(:plan) { create(:plan, :considering, created_by_user: author) }

  describe "POST /plans/:plan_id/attachments" do
    it "uploads files for the plan author and logs events" do
      sign_in_as(author)

      expect {
        post plan_attachments_path(plan), params: {
          files: [ fixture_file_upload("sample.png", "image/png"), fixture_file_upload("sample.txt", "text/plain") ]
        }
      }.to change { plan.attachments_attachments.count }.by(2)
        .and change { plan.plan_events.where(event_type: "attachment_added").count }.by(2)

      expect(response).to redirect_to(plan_path(plan, tab: "attachments"))
      follow_redirect!
      expect(flash[:notice]).to include("2 files uploaded")

      event = plan.plan_events.where(event_type: "attachment_added").first
      expect(event.actor_type).to eq("human")
      expect(event.actor_id).to eq(author.id)
    end

    it "surfaces per-file validation errors" do
      sign_in_as(author)

      post plan_attachments_path(plan), params: {
        files: [ fixture_file_upload("sample.html", "text/html") ]
      }

      expect(response).to redirect_to(plan_path(plan, tab: "attachments"))
      expect(flash[:alert]).to include("sample.html")
      expect(flash[:alert]).to include("not allowed")
      expect(plan.attachments.count).to eq(0)
    end

    it "accepts uploads from any signed-in user, crediting them as actor" do
      sign_in_as(viewer)

      expect {
        post plan_attachments_path(plan), params: {
          files: [ fixture_file_upload("sample.png", "image/png") ]
        }
      }.to change { plan.attachments_attachments.count }.by(1)

      expect(response).to redirect_to(plan_path(plan, tab: "attachments"))
      event = plan.plan_events.find_by(event_type: "attachment_added")
      expect(event.actor_id).to eq(viewer.id)
    end

    it "rejects uploads from signed-out visitors" do
      post plan_attachments_path(plan), params: {
        files: [ fixture_file_upload("sample.png", "image/png") ]
      }

      expect(response).to have_http_status(:redirect)
      expect(response.location).to include("sign_in")
      expect(plan.attachments.count).to eq(0)
    end
  end

  describe "DELETE /plans/:plan_id/attachments/:id" do
    before do
      plan.attachments.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/sample.png")),
        filename: "sample.png",
        content_type: "image/png"
      )
    end

    it "removes the attachment for the plan author and logs an event" do
      sign_in_as(author)
      attachment = plan.attachments_attachments.first

      expect {
        delete plan_attachment_path(plan, attachment)
      }.to change { plan.attachments_attachments.count }.by(-1)

      expect(response).to redirect_to(plan_path(plan, tab: "attachments"))
      event = plan.plan_events.find_by(event_type: "attachment_removed")
      expect(event.before_value).to eq("sample.png")
    end

    it "rejects deletes from non-authors" do
      sign_in_as(viewer)
      attachment = plan.attachments_attachments.first

      delete plan_attachment_path(plan, attachment)
      expect(response).to have_http_status(:not_found)
      expect(plan.attachments_attachments.count).to eq(1)
    end
  end

  describe "plan show page" do
    it "renders the attachments tab with uploads and download links" do
      plan.attachments.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/sample.png")),
        filename: "diagram.png",
        content_type: "image/png"
      )

      sign_in_as(viewer)
      get plan_path(plan, tab: "attachments")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("diagram.png")
      expect(response.body).to include("disposition=attachment")
      # Anyone signed in can add attachments; only the author can delete.
      expect(response.body).to include("attachments-upload")
      expect(response.body).not_to include("attachments-list__remove")
    end

    it "shows the upload form to the plan author" do
      sign_in_as(author)
      get plan_path(plan, tab: "attachments")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("attachments-upload")
    end
  end
end
