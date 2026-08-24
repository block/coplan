require "rails_helper"

RSpec.describe "Home feed", type: :request do
  let(:viewer) { create(:coplan_user, name: "Vera Viewer") }
  let(:author) { create(:coplan_user, name: "Ada Author") }

  before { sign_in_as(viewer) }

  describe "GET /home" do
    it "shows recently created published plans" do
      create(:plan, :considering, created_by_user: author, title: "Fresh Plan")

      get home_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Fresh Plan")
      # First appearance reads as "new" — published is the unmarked normal state.
      expect(response.body).to include("home__item-activity--new")
      expect(response.body).not_to include("published ·")
    end

    it "never shows drafts or archived plans — not even your own" do
      create(:plan, :draft, created_by_user: viewer, title: "My Secret Draft")
      create(:plan, :considering, created_by_user: author, title: "Old News", archived_at: 1.hour.ago)

      get home_path
      expect(response.body).not_to include("My Secret Draft")
      expect(response.body).not_to include("Old News")
    end

    it "rolls up edits and comments per plan per day" do
      plan = create(:plan, :considering, created_by_user: author, title: "Busy Plan")
      create(:plan_version, plan: plan, revision: 2)
      create(:plan_version, plan: plan, revision: 3)
      thread = create(:comment_thread, plan: plan, created_by_user: viewer)
      create(:comment, comment_thread: thread)

      get home_path
      # One rollup line, not one entry per revision.
      expect(response.body.scan("Busy Plan").size).to eq(1)
      expect(response.body).to include("2 edits")
      expect(response.body).to include("1 comment")
    end

    # A tag spans libraries, so it isn't a place inside one and has no path
    # in anybody's — the Feed is where "everyone's work on this" lives now
    # that the workspace has no everyone's-plans mode to link to.
    describe "?tag=" do
      before do
        create(:plan, :considering, created_by_user: author, title: "Checkout Rewrite", tag_names: [ "payments" ])
        create(:plan, :considering, created_by_user: author, title: "Nav Refresh", tag_names: [ "design" ])
      end

      it "narrows the feed to one tag" do
        get home_path(tag: "payments")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Checkout Rewrite")
        expect(response.body).not_to include("Nav Refresh")
      end

      it "offers a way back out, and says so when the tag has nothing" do
        get home_path(tag: "payments")
        expect(response.body).to include("Clear #payments filter")

        get home_path(tag: "nobody-uses-this")
        expect(response.body).to include("No published activity tagged #nobody-uses-this")
        expect(response.body).not_to include("Checkout Rewrite")
      end

      # The chips on each row are what put a tag in the URL, so they have to
      # point at the page that reads it.
      it "is where a row's own tag chip points" do
        get home_path

        expect(response.body).to include(%(href="#{home_path(tag: 'payments')}"))
      end
    end

    it "shows an empty state when nothing happened recently" do
      plan = create(:plan, :considering, created_by_user: author, title: "Ancient Plan")
      plan.plan_versions.update_all(created_at: 2.months.ago)
      plan.update_columns(created_at: 2.months.ago, updated_at: 2.months.ago)

      get home_path
      expect(response.body).to include("No published activity")
      expect(response.body).not_to include("Ancient Plan")
    end
  end
end
