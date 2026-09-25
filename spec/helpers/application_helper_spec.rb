require "rails_helper"

RSpec.describe CoPlan::ApplicationHelper, type: :helper do
  describe "#user_avatar" do
    it "renders accessible initials without an image when no photo is set" do
      user = build(:coplan_user, name: "Ada Marie Lovelace", avatar_url: nil)
      avatar = Nokogiri::HTML.fragment(helper.user_avatar(user, size: "lg"))

      expect(avatar.at_css(".avatar--lg[role='img']")["aria-label"]).to eq(user.name)
      expect(avatar.text).to eq("AM")
      expect(avatar.css("img")).to be_empty
    end

    it "keeps escaped initials underneath a lazy photo and preserves viewer styling" do
      user = build(:coplan_user, name: "<Alex> &Morgan", avatar_url: "https://example.com/photo.png")
      avatar = Nokogiri::HTML.fragment(helper.user_avatar(user, css_class: "plan-viewers__avatar plan-viewers__avatar--you"))

      expect(avatar.at_css(".plan-viewers__avatar--you").text).to eq("<&")
      expect(avatar.at_css("img")["src"]).to eq(user.avatar_url)
      expect(avatar.at_css("img")["loading"]).to eq("lazy")
      expect(avatar.at_css("img")["data-controller"]).to eq("coplan--avatar")
      expect(avatar.css("alex")).to be_empty
    end
  end

  describe "#plan_og_description" do
    let(:plan) { create(:plan, :published, title: "My Plan") }

    it "includes the plan state and author" do
      result = helper.plan_og_description(plan)
      expect(result).to include("Plan")
      expect(result).to include(plan.created_by_user.name)
    end

    it "labels private and archived plans" do
      draft = create(:plan, :draft)
      archived = create(:plan, archived_at: 1.day.ago)
      expect(helper.plan_og_description(draft)).to start_with("Private")
      expect(helper.plan_og_description(archived)).to start_with("Archived")
    end

    it "includes a content excerpt when content is present" do
      plan.current_plan_version.update!(content_markdown: "# Overview\n\nThis is the summary of the plan.")
      result = helper.plan_og_description(plan)
      expect(result).to include("This is the summary of the plan.")
    end

    it "returns only prefix when plan has no version" do
      plan.update_columns(current_plan_version_id: nil)
      plan.reload
      result = helper.plan_og_description(plan)
      # Published is the unmarked state, and every plan carries a type
      # (General by default), so with no content the context is type + author.
      expect(result).to eq("General · by #{plan.created_by_user.name}")
    end

    it "truncates long content" do
      long_text = "A" * 500
      plan.current_plan_version.update!(content_markdown: long_text)
      result = helper.plan_og_description(plan)
      expect(result.length).to be <= 250
    end
  end
end
