require "rails_helper"

RSpec.describe "Comments", type: :request do
  let(:alice) { create(:coplan_user, :admin) }
  let(:plan) { create(:plan, :considering, created_by_user: alice) }
  let(:thread_record) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: alice) }

  before { sign_in_as(alice) }

  it "create reply" do
    expect {
      post plan_comment_thread_comments_path(plan, thread_record), params: {
        comment: { body_markdown: "I agree with this." }
      }
    }.to change(CoPlan::Comment, :count).by(1)
    expect(response).to redirect_to(plan_path(plan))
    comment = CoPlan::Comment.last
    expect(comment.author_type).to eq("human")
    expect(comment.author_id).to eq(alice.id)
  end

  it "does not calculate a template digest while broadcasting a reply" do
    original_perform_caching = ActionController::Base.perform_caching
    ActionController::Base.perform_caching = true
    allow(ActionView::Digestor).to receive(:digest).and_call_original
    allow(Rails.cache).to receive(:read).and_call_original

    post plan_comment_thread_comments_path(plan, thread_record), params: {
      comment: { body_markdown: "This should return without digesting the partial." }
    }

    expect(Rails.cache).to have_received(:read)
    expect(ActionView::Digestor).not_to have_received(:digest)
  ensure
    ActionController::Base.perform_caching = original_perform_caching
  end

  describe "DELETE destroy" do
    let!(:comment) do
      create(:comment, comment_thread: thread_record, author_type: "human", author_id: alice.id, body_markdown: "to be deleted")
    end

    it "soft-deletes the author's own comment" do
      expect {
        delete plan_comment_thread_comment_path(plan, thread_record, comment)
      }.to change { comment.reload.deleted_at }.from(nil)
      expect(response).to redirect_to(plan_path(plan))
    end

    it "redirects with alert when the user is not the comment author" do
      bob = create(:coplan_user)
      bobs_comment = create(:comment, comment_thread: thread_record, author_type: "human", author_id: bob.id, body_markdown: "alice can't touch this")

      delete plan_comment_thread_comment_path(plan, thread_record, bobs_comment)
      expect(bobs_comment.reload.deleted_at).to be_nil
      expect(flash[:alert]).to be_present
    end

    it "empties the thread when the last kept comment is deleted" do
      delete plan_comment_thread_comment_path(plan, thread_record, comment)
      expect(thread_record.reload).to be_empty
    end

    it "leaves the thread populated when a reply remains" do
      create(:comment, comment_thread: thread_record, author_type: "human", author_id: alice.id, body_markdown: "reply")
      delete plan_comment_thread_comment_path(plan, thread_record, comment)
      expect(thread_record.reload).not_to be_empty
    end
  end
end
