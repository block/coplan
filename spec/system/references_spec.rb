require "rails_helper"

RSpec.describe "Plan references", type: :system do
  let(:user) { create(:coplan_user, email: "refuser@example.com") }
  let(:plan) do
    p = CoPlan::Plan.create!(title: "Test Plan", created_by_user: user)
    version = CoPlan::PlanVersion.create!(
      plan: p, revision: 1,
      content_markdown: "# Hello\n\nSome content here.",
      actor_type: "human", actor_id: user.id
    )
    p.update!(current_plan_version: version, current_revision: 1)
    p
  end

  before do
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_current_path(root_path)
  end

  describe "tab navigation" do
    it "shows plan content by default and hides references" do
      visit plan_path(plan)
      expect(page).to have_content("Hello")
      expect(page).not_to have_content("No references yet")
    end

    it "clicking References tab shows references and hides content" do
      visit plan_path(plan)
      click_link "References"

      expect(page).to have_content("No references yet")
      expect(page).not_to have_content("Some content here")
    end

    it "clicking back to Content tab restores plan content" do
      visit plan_path(plan)
      click_link "References"
      expect(page).to have_content("No references yet")

      click_link "Content"
      expect(page).to have_content("Some content here")
      expect(page).not_to have_content("No references yet")
    end

    it "preserves tab selection via URL param on page load" do
      visit plan_path(plan, tab: "references")
      expect(page).to have_content("No references yet")
      expect(page).not_to have_content("Some content here")
    end

    it "updates the URL when switching tabs" do
      visit plan_path(plan)
      click_link "References"
      uri = URI.parse(current_url)
      expect(Rack::Utils.parse_query(uri.query)).to include("tab" => "references")
    end

    it "removes tab param when switching back to content" do
      visit plan_path(plan, tab: "references")
      click_link "Content"
      uri = URI.parse(current_url)
      expect(uri.query.to_s).not_to include("tab=")
    end
  end

  describe "adding references" do
    it "adds a reference inline without page navigation" do
      visit plan_path(plan, tab: "references")
      original_url = current_url

      find("summary", text: "+ Add Reference").click
      fill_in "reference[url]", with: "https://github.com/org/repo"
      fill_in "reference[title]", with: "My Repo"
      fill_in "reference[key]", with: "my-repo"
      click_button "Add"

      # Reference appears
      expect(page).to have_link("My Repo", href: "https://github.com/org/repo")
      # Empty state gone
      expect(page).not_to have_content("No references yet")
      # Tab count updated
      expect(page).to have_css("#references-count", text: "1")
      # Still on references tab (not redirected to content)
      expect(page).to have_content("My Repo")
      expect(page).not_to have_content("Some content here")
    end

    it "adds multiple references in sequence" do
      visit plan_path(plan, tab: "references")

      find("summary", text: "+ Add Reference").click

      fill_in "reference[url]", with: "https://github.com/org/repo"
      fill_in "reference[title]", with: "Repo One"
      click_button "Add"
      expect(page).to have_content("Repo One")
      expect(page).to have_css("#references-count", text: "1")

      # Form should be available again for another add
      find("summary", text: "+ Add Reference").click
      fill_in "reference[url]", with: "https://github.com/org/other"
      fill_in "reference[title]", with: "Repo Two"
      click_button "Add"
      expect(page).to have_content("Repo Two")
      expect(page).to have_css("#references-count", text: "2")
    end

    it "auto-classifies URL types" do
      visit plan_path(plan, tab: "references")
      find("summary", text: "+ Add Reference").click

      fill_in "reference[url]", with: "https://github.com/org/repo/pull/42"
      fill_in "reference[title]", with: "Fix PR"
      click_button "Add"

      expect(page).to have_css(".badge--ref-type", text: /pull request/i)
    end
  end

  describe "removing references" do
    it "removes an explicit reference inline" do
      create(:reference, plan: plan, url: "https://example.com", title: "Doomed", source: "explicit")

      visit plan_path(plan, tab: "references")
      expect(page).to have_content("Doomed")
      expect(page).to have_css("#references-count", text: "1")

      accept_confirm("Remove this reference?") do
        click_button "✕"
      end

      expect(page).not_to have_content("Doomed")
      expect(page).to have_css("#references-count", text: "0")
      expect(page).to have_content("No references yet")
    end

    it "does not show delete button for auto-extracted references" do
      plan.current_plan_version.update!(
        content_markdown: "See [Rails](https://rubyonrails.org) for details."
      )
      CoPlan::References::ExtractFromContent.call(plan: plan)

      visit plan_path(plan, tab: "references")
      expect(page).to have_content("Rails")
      expect(page).not_to have_button("✕")
    end
  end

  describe "auto-extraction from content edits" do
    it "extracts references when a new version is created" do
      # Simulate an API edit creating a new version with links
      CoPlan::PlanVersion.create!(
        plan: plan,
        revision: plan.current_revision + 1,
        content_markdown: "See [Auth Service](https://github.com/org/auth) and [Design Doc](https://docs.google.com/document/d/abc).",
        actor_type: "human",
        actor_id: user.id
      )

      visit plan_path(plan, tab: "references")
      expect(page).to have_content("Auth Service")
      expect(page).to have_content("Design Doc")
      expect(page).to have_css("#references-count", text: "2")
      expect(page).to have_css(".badge--ref-type", text: /repository/i)
      expect(page).to have_css(".badge--ref-type", text: /document/i)
    end

    it "removes extracted references when links are removed from content" do
      plan.current_plan_version.update!(
        content_markdown: "See [Rails](https://rubyonrails.org) and [Ruby](https://ruby-lang.org)."
      )
      CoPlan::References::ExtractFromContent.call(plan: plan)
      expect(plan.references.count).to eq(2)

      # New version without the Ruby link
      CoPlan::PlanVersion.create!(
        plan: plan,
        revision: plan.current_revision + 1,
        content_markdown: "See [Rails](https://rubyonrails.org) only.",
        actor_type: "human",
        actor_id: user.id
      )

      visit plan_path(plan, tab: "references")
      expect(page).to have_content("Rails")
      expect(page).not_to have_content("Ruby")
      expect(page).to have_css("#references-count", text: "1")
    end

    it "preserves explicit references when content changes" do
      create(:reference, plan: plan, url: "https://example.com/important", title: "Important Link", source: "explicit")

      CoPlan::PlanVersion.create!(
        plan: plan,
        revision: plan.current_revision + 1,
        content_markdown: "Completely new content with no links.",
        actor_type: "human",
        actor_id: user.id
      )

      visit plan_path(plan, tab: "references")
      expect(page).to have_content("Important Link")
      expect(page).to have_css("#references-count", text: "1")
    end

    it "extracts keyed references from markdown reference-style links" do
      CoPlan::PlanVersion.create!(
        plan: plan,
        revision: plan.current_revision + 1,
        content_markdown: "See the [auth-repo] for details.\n\n[auth-repo]: https://github.com/org/auth \"Auth Service\"",
        actor_type: "human",
        actor_id: user.id
      )

      visit plan_path(plan, tab: "references")
      expect(page).to have_content("Auth Service")
      expect(page).to have_css(".badge--ref-key", text: /auth-repo/i)
    end
  end

  describe "display" do
    it "shows key badge for keyed references" do
      create(:reference, plan: plan, url: "https://github.com/org/repo", key: "main-repo", title: "Main Repo", source: "explicit")

      visit plan_path(plan, tab: "references")
      expect(page).to have_css(".badge--ref-key", text: /main-repo/i)
    end

    it "shows source label for auto-extracted references" do
      create(:reference, plan: plan, url: "https://example.com", source: "extracted")

      visit plan_path(plan, tab: "references")
      expect(page).to have_content("auto-extracted")
    end

    it "links open in new tab" do
      create(:reference, plan: plan, url: "https://example.com", title: "External", source: "explicit")

      visit plan_path(plan, tab: "references")
      link = find("a", text: "External")
      expect(link[:target]).to eq("_blank")
      expect(link[:rel]).to include("noopener")
    end

    it "truncates long URLs when no title is set" do
      long_url = "https://github.com/organization/very-long-repository-name-that-goes-on-and-on/pull/12345"
      create(:reference, plan: plan, url: long_url, title: nil, source: "explicit")

      visit plan_path(plan, tab: "references")
      # Should show a truncated version, not the full URL
      expect(page).to have_link(href: long_url)
    end
  end
end
