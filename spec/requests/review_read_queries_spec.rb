require "rails_helper"

RSpec.describe "Review reader queries", type: :request do
  let(:author) { create(:coplan_user) }
  let(:plan) { create(:plan, :published, created_by_user: author, reset_reviews_on_change: false) }

  def add_approval
    reviewer = create(:coplan_user)
    request = CoPlan::Reviews::Request.call(plan: plan, reviewer: reviewer, actor: author)
    CoPlan::Reviews::Respond.call(request: request, actor: reviewer, revision: plan.current_revision, decision: "approved")
  end

  def advance_version
    CoPlan::Plans::ReplaceContent.call(plan: plan, new_content: "#{plan.current_content}\nMore detail.\n",
      base_revision: plan.current_revision, actor_type: "human", actor_id: author.id)
  end

  def response_queries
    count = 0
    subscriber = lambda do |*, payload|
      count += 1 if !payload[:cached] && payload[:sql].match?(/\bFROM\s+[`"]coplan_review_responses[`"] /i)
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    expect(response).to have_http_status(:ok)
    count
  end

  %i[controls api snapshot].each do |reader|
    it "keeps #{reader} response queries constant as retained reviews grow" do
      sign_in_as(author)
      create(:api_token, user: author, raw_token: "query-review-owner", agent_name: "Querybot")
      add_approval
      advance_version
      path = case reader
      when :controls then plan_review_requests_path(plan)
      when :api then api_v1_plan_review_requests_path(plan)
      when :snapshot then snapshot_api_v1_plan_path(plan)
      end
      headers = { "Authorization" => "Bearer query-review-owner" }
      few = response_queries { get path, headers: headers }

      3.times { add_approval }
      advance_version
      many = response_queries { get path, headers: headers }

      if reader == :controls
        expect(Nokogiri::HTML(response.body).css(".review-table tbody .review-person").size).to eq(4)
        expect(response.body).to include("Current: v3")
      else
        reviews = response.parsed_body.fetch("review_requests")
        expect(reviews.size).to eq(4)
        expect(reviews).to all(include("review_status" => "approved", "effective_status" => "pending"))
        expect(reviews.map { |review| review.fetch("recorded_response_id") }).to all(be_present)
      end
      expect(many).to eq(few)
    end
  end
end
