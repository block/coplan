require "rails_helper"

RSpec.describe "Admin permanent comment deletion", type: :request do
  let(:admin) { create(:coplan_user, admin: true) }
  let(:comment) { create(:comment, body_markdown: "Retained original comment") }
  let(:path) { "/_/admin/plan_comments/#{comment.id}/permanently_delete" }

  it "rejects a non-admin even for their own soft-deleted comment" do
    user = create(:coplan_user)
    comment.update!(author_type: "human", author_id: user.id)
    comment.soft_delete!
    sign_in_as(user)
    delete path, params: { confirmation: "DELETE" }, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(comment.reload.body_markdown).to eq("Retained original comment")
  end

  it "requires explicit confirmation and prior soft deletion" do
    sign_in_as(admin)
    delete path, params: { confirmation: "DELETE" }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    comment.soft_delete!
    delete path, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(comment.reload.body_markdown).to eq("Retained original comment")
  end

  it "lets an admin inspect and explicitly permanently delete retained text" do
    comment.soft_delete!
    sign_in_as(admin)
    get "/_/admin/plan_comments/#{comment.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Retained original comment", "Permanently delete comment", "Type DELETE")

    delete path, params: { confirmation: "DELETE" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["html"]).to include("Comment permanently deleted")
    expect(CoPlan::Comment.exists?(comment.id)).to be(false)
  end

  it "accepts the form's authenticity token when CSRF protection is enabled" do
    comment.soft_delete!
    sign_in_as(admin)
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get "/_/admin/plan_comments/#{comment.id}"
    token = Nokogiri::HTML(response.body).at_css('input[name="authenticity_token"]')["value"]

    delete path, params: { confirmation: "DELETE", authenticity_token: token }, as: :json
    expect(response).to have_http_status(:ok)
    expect(CoPlan::Comment.exists?(comment.id)).to be(false)
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
end
