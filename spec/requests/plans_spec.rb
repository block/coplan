require "rails_helper"

RSpec.describe "Plans", type: :request do
  let(:alice) { create(:coplan_user, :admin) }
  let(:bob) { create(:coplan_user) }
  let(:plan) { create(:plan, :considering, created_by_user: alice) }
  let(:brainstorm_plan) { create(:plan, :brainstorm, created_by_user: alice) }

  before { sign_in_as(alice) }

  it "index shows plans" do
    plan # trigger creation
    get library_page_path(alice)
    expect(response).to have_http_status(:success)
    expect(response.body).to include(plan.title)
  end

  it "index filters by status" do
    plan # trigger creation
    get library_page_path(alice, status: "considering")
    expect(response).to have_http_status(:success)
    expect(response.body).to include(plan.title)
  end

  # A library is one person's shelf, so there is nothing to filter: someone
  # else's plan is on their page, never on yours.
  it "index shows only the library owner's plans" do
    plan # created by alice
    bobs_plan = create(:plan, :considering, created_by_user: bob)
    get library_page_path(alice)
    expect(response).to have_http_status(:success)
    expect(response.body).to include(plan.title)
    expect(response.body).not_to include(bobs_plan.title)
  end

  it "index filters by tag" do
    plan.tag_names = [ "infra" ]
    other = create(:plan, :considering, created_by_user: alice, title: "Other Plan")
    other.tag_names = [ "frontend" ]
    get library_page_path(alice, tag: "infra")
    expect(response).to have_http_status(:success)
    expect(response.body).to include(plan.title)
    expect(response.body).not_to include("Other Plan")
  end

  it "index lists tags in the sidebar, not as chips on the rows" do
    plan.tag_names = [ "infra", "api" ]
    get library_page_path(alice)
    expect(response.body).to include("#infra")
    expect(response.body).to include("#api")
    # Row tag chips were dropped: they crowded the byline off its corner
    # and the sidebar already filters by tag.
    expect(response.body).not_to include("badge--tag")
  end

  it "index shows active tag filter bar" do
    plan.tag_names = [ "infra" ]
    get library_page_path(alice, tag: "infra")
    expect(response.body).to include("active-filter")
    expect(response.body).to include("infra")
    expect(response.body).to include("Clear")
  end

  it "show plan keeps tags off the reading surface" do
    # Tags are workspace-side organization (sidebar filters, the editor) —
    # the plan page masthead stays two clean rows: title, then byline.
    plan.tag_names = [ "infra", "security" ]
    get plan_page_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).not_to include("badge--tag")
  end

  it "show plan renders successfully" do
    get plan_page_path(plan)
    expect(response).to have_http_status(:success)
  end

  it "show plan renders plan content" do
    get plan_page_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include("plan-layout__content")
  end

  it "does not link archived plans to a library that omits them" do
    archived_plan = create(:plan, :archived, created_by_user: alice)

    get plan_page_path(archived_plan)

    expect(response).to have_http_status(:success)
    expect(response.body).not_to include("plan-location-link")
  end

  it "scopes comment footnote ids so they can't collide with the plan body's" do
    thread = create(:comment_thread, :with_anchor, plan: plan, plan_version: plan.current_plan_version, created_by_user: alice)
    comment = create(:comment, comment_thread: thread, author_type: "human", author_id: alice.id,
                     body_markdown: "Noted.[^1]\n\n[^1]: A comment footnote.")

    get plan_page_path(plan)
    expect(response.body).to include(%(id="comment-#{comment.id}-fn-1"))
    expect(response.body).to include(%(href="#comment-#{comment.id}-fn-1"))
  end

  it "show plan renders content navigation sidebar" do
    get plan_page_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include('class="content-nav"')
    expect(response.body).to include('data-coplan--content-nav-target="sidebar"')
    expect(response.body).to include('data-coplan--content-nav-target="list"')
    expect(response.body).to include("content-nav-show-btn")
  end

  it "show plan wires up both text-selection and content-nav controllers" do
    get plan_page_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include('data-controller="coplan--text-selection coplan--content-nav coplan--checkbox coplan--changed-sections coplan--reference-preview"')
    expect(response.body).to include('data-coplan--reference-preview-target="popover"')
  end

  it "show plan shares content target between controllers" do
    get plan_page_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include('data-coplan--content-nav-target="content"')
    expect(response.body).to include('data-coplan--text-selection-target="content"')
  end

  it "show presentation plan wires up the deck presenter with a Present control" do
    deck_type = create(:plan_type, name: "Presentation", behavior: "presentation")
    deck_plan = create(:plan, plan_type: deck_type, created_by_user: alice)
    get plan_page_path(deck_plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include('data-controller="coplan--deck-presenter"')
    expect(response.body).to include('data-action="coplan--deck-presenter#start"')
  end

  it "show document plan renders no presenter chrome" do
    get plan_page_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).not_to include("deck-presenter")
    expect(response.body).not_to include("deck-toolbar")
  end

  it "show plan without content does not render content nav sidebar" do
    empty_plan = create(:plan, :considering, created_by_user: alice)
    empty_plan.current_plan_version.update_columns(content_markdown: "", content_sha256: Digest::SHA256.hexdigest(""))
    get plan_page_path(empty_plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include("empty-state")
    expect(response.body).not_to include('class="content-nav"')
  end

  it "show plan includes Open Graph meta tags" do
    get plan_page_path(plan)
    expect(response.body).to include('property="og:title"')
    expect(response.body).to include('property="og:description"')
    expect(response.body).to include('property="og:site_name"')
    expect(response.body).to include('name="twitter:card"')
  end

  it "show plan includes turbo stream subscription" do
    get plan_page_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include("turbo-cable-stream-source")
  end

  it "update plan updates title without creating a version" do
    plan # trigger creation
    expect {
      patch plan_path(plan), params: {
        plan: { title: "Updated Title" }
      }
    }.not_to change(CoPlan::PlanVersion, :count)
    plan.reload
    expect(plan.title).to eq("Updated Title")
    expect(response).to redirect_to(plan_page_path(plan))
  end

  it "index hides other users brainstorm plans when you visit their library" do
    brainstorm_plan # alice's brainstorm
    sign_in_as(bob)
    get library_page_path(alice)
    expect(response).to have_http_status(:success)
    expect(response.body).not_to include(brainstorm_plan.title)
  end

  it "index shows own brainstorm plans" do
    brainstorm_plan # alice's brainstorm
    get library_page_path(alice)
    expect(response).to have_http_status(:success)
    expect(response.body).to include(brainstorm_plan.title)
  end

  describe "whose shelf you are looking at" do
    it "shows the owner's plans and nobody else's" do
      plan # alice's
      bobs_plan = create(:plan, :considering, created_by_user: bob, title: "Bobs Roadmap")
      get library_page_path(alice)
      expect(response.body).to include(plan.title)
      expect(response.body).not_to include(bobs_plan.title)
    end

    # Everyone's work is still reachable — it lives at their address, not
    # behind a scope toggle on yours.
    it "shows someone else's published plans on their own page" do
      plan # alice's
      bobs_plan = create(:plan, :considering, created_by_user: bob, title: "Bobs Roadmap")
      get library_page_path(bob)
      expect(response.body).to include(bobs_plan.title)
      expect(response.body).not_to include(plan.title)
    end

    it "lists folders and loose docs at the root level; filed docs live inside their folder" do
      root = create(:folder, name: "Team EBT", created_by_user: alice)
      filed = create(:plan, :published, created_by_user: alice, title: "Filed Plan")
      CoPlan::Plans::Place.call(plan: filed, folder: root, actor: alice)
      create(:plan, :published, created_by_user: alice, title: "Loose Plan")

      get library_page_path(alice)

      expect(response.body).to include("folder-row")
      expect(response.body).to include("Team EBT")
      expect(response.body).to include("Loose Plan")
      # The filed doc is one click away, not flattened into the root list.
      expect(response.body).not_to include("Filed Plan")
    end

    it "shows one level at a time: entering a folder shows its subfolders, not their contents" do
      root = create(:folder, name: "Team EBT", created_by_user: alice)
      sub = create(:folder, name: "Q3", parent: root, created_by_user: alice)
      nested = create(:plan, :published, created_by_user: alice, title: "Nested Plan")
      CoPlan::Plans::Place.call(plan: nested, folder: sub, actor: alice)

      get folder_page_path(root)
      expect(response.body).to include("Q3")
      expect(response.body).not_to include("Nested Plan")

      get folder_page_path(sub)
      expect(response.body).to include("Nested Plan")
    end

    it "renders empty folders — an empty folder is a place to put things" do
      create(:folder, name: "Empty Folder", created_by_user: alice)
      create(:plan, :published, created_by_user: alice)

      get library_page_path(alice)

      expect(response.body).to include("Empty Folder")
      expect(response.body).to match(/folder-row__count[^>]*>\s*empty\s*</)
    end

    it "mixes private plans into the level view instead of a separate group" do
      create(:plan, :draft, created_by_user: alice, title: "Quiet Draft")
      create(:plan, :published, created_by_user: alice, title: "Published Plan")

      get library_page_path(alice)

      expect(response.body).to include("Quiet Draft")
      expect(response.body).to include("Published Plan")
    end

    it "keeps folders visible on the first page despite many loose docs" do
      root = create(:folder, name: "Team EBT", created_by_user: alice)
      filed = create(:plan, :published, created_by_user: alice, title: "Small Folder Plan")
      CoPlan::Plans::Place.call(plan: filed, folder: root, actor: alice)
      create_list(:plan, CoPlan::PlansController::PER_PAGE + 5, :published, created_by_user: alice)

      get library_page_path(alice)

      expect(response).to have_http_status(:success)
      expect(response.body).to include("Team EBT")
    end

    it "paginates the level's doc list via a lazy frame" do
      create_list(:plan, CoPlan::PlansController::PER_PAGE + 2, :published, created_by_user: alice)
      get library_page_path(alice)
      expect(response.body).to include('id="plans-level-page-2"')
      expect(response.body).to include("group=level")
    end

    it "paginates inside a folder with the folder scope carried on the frame" do
      root = create(:folder, name: "Team EBT", created_by_user: alice)
      create_list(:plan, CoPlan::PlansController::PER_PAGE + 2, :published, created_by_user: alice).each do |p|
        CoPlan::Plans::Place.call(plan: p, folder: root, actor: alice)
      end

      get folder_page_path(root)

      expect(response.body).to include('id="plans-level-page-2"')
      # The next-page frame still has to know which folder it's paging, and
      # it names it the way the rest of the app does: in the path. A
      # `?folder=<id>` here would be the last place that didn't.
      expect(response.body).to include(browse_path(handle: alice.library.handle, slug_path: "team-ebt"))
    end

    it "serves level page fetches without leaking filed plans into the root" do
      root = create(:folder, name: "Team EBT", created_by_user: alice)
      filed = create(:plan, :published, created_by_user: alice, title: "Filed Plan")
      CoPlan::Plans::Place.call(plan: filed, folder: root, actor: alice)
      create(:plan, :published, created_by_user: alice, title: "Loose Plan")

      get library_page_path(alice, group: "level", page: 1), headers: { "Turbo-Frame" => "plans-level-page-1" }

      expect(response.body).to include("Loose Plan")
      expect(response.body).not_to include("Filed Plan")
    end

    it "renders a flat list (no folder rows) when filtered to a single visibility" do
      create(:folder, name: "Team EBT", created_by_user: alice)
      create(:plan, :published, created_by_user: alice, title: "Published Plan")
      get library_page_path(alice, filter: "published")
      expect(response.body).not_to include("folder-row")
      expect(response.body).to include("Published Plan")
    end

    it "shows the library owner's visible plans at the root level" do
      create(:plan, :published, created_by_user: bob, title: "Bobs Published Plan")
      get library_page_path(bob)
      expect(response.body).to include("Bobs Published Plan")
    end
  end

  # The strip covers the library you're looking at, so on your own page it
  # is your own work.
  describe "since you last looked" do
    it "flags plans updated after the viewer's last visit" do
      seen_plan = create(:plan, :published, created_by_user: alice, title: "Moved On")
      create(:plan_viewer, plan: seen_plan, user: alice, last_seen_at: 2.days.ago)
      seen_plan.update!(updated_at: 1.hour.ago)

      get library_page_path(alice)

      expect(response.body).to include("Since you last looked")
      expect(response.body).to include("recent-updates__badge--updated")
    end

    # Only on their page: "new to you" needs someone else's work, and your
    # own library is yours alone now that a plan can't be filed onto two
    # shelves.
    it "flags never-opened plans by other people as new to you" do
      create(:plan, :published, created_by_user: bob, title: "Fresh From Bob")

      get library_page_path(bob)

      expect(response.body).to include("recent-updates__badge--new-to-you")
      expect(response.body).to include("Fresh From Bob")
    end

    it "does not flag the viewer's own unopened plans" do
      create(:plan, :published, created_by_user: alice, title: "My Own Plan")

      get library_page_path(alice)

      expect(response.body).not_to include("Since you last looked")
    end

    it "does not flag plans the viewer has seen since their last update" do
      seen_plan = create(:plan, :published, created_by_user: bob, title: "Old News")
      create(:plan_viewer, plan: seen_plan, user: alice, last_seen_at: Time.current)

      get library_page_path(bob)

      expect(response.body).not_to include("Since you last looked")
    end

    it "omits archived plans even when recently touched" do
      buried = create(:plan, :archived, created_by_user: bob, title: "Archived But Fresh")
      buried.update!(updated_at: 1.minute.ago)

      get library_page_path(bob)

      expect(response.body).not_to include("Archived But Fresh")
    end

    it "caps the strip at RECENT_LIMIT entries" do
      7.times { |i| create(:plan, :published, created_by_user: bob, title: "Bulk Update #{i}") }

      get library_page_path(bob)

      count = response.body.scan("recent-updates__badge--new-to-you").size
      expect(count).to eq(CoPlan::PlansController::RECENT_LIMIT)
    end

    it "only considers the newest RECENT_CANDIDATES plans" do
      stale = create(:plan, :published, created_by_user: bob, title: "Ancient Unseen")
      stale.update!(updated_at: 1.year.ago)
      CoPlan::PlansController::RECENT_CANDIDATES.times do |i|
        create(:plan, :published, created_by_user: bob, title: "Noise #{i}")
      end

      get library_page_path(bob)

      expect(response.body).not_to include("Ancient Unseen")
    end
  end

  describe "document type prominence" do
    it "leads rows with the type's file icon, name in the tooltip — never a chip" do
      rfc = create(:plan_type, name: "RFC", icon: "scroll")
      create(:plan, :published, created_by_user: alice, plan_type: rfc, title: "Typed Plan")
      get library_page_path(alice)
      expect(response.body).to include("plan-type-icon")
      expect(response.body).to include('title="RFC"')
      expect(response.body).to include('aria-label="RFC document"')
      expect(response.body).not_to include("plan-type-chip")
    end

    it "colors the icon with a stable per-name tint" do
      rfc = create(:plan_type, name: "RFC", icon: "scroll")
      create(:plan, :published, created_by_user: alice, plan_type: rfc)
      get library_page_path(alice)
      tint = Zlib.crc32("RFC") % CoPlan::PlansHelper::PLAN_TYPE_COLOR_COUNT
      expect(response.body).to include("plan-type-icon--#{tint}")
    end

    it "falls back to the document glyph for unknown icon names" do
      weird = create(:plan_type, name: "Mystery Type", icon: "definitely-not-real")
      create(:plan, :published, created_by_user: alice, plan_type: weird)
      get library_page_path(alice)
      expect(response.body).to include("plan-type-icon")
      expect(response.body).to include('title="Mystery Type"')
    end

    it "renders the General type icon for plans created without an explicit type" do
      create(:plan, :published, created_by_user: alice, plan_type: nil)
      get library_page_path(alice)
      expect(response.body).to include('aria-label="General document"')
      tint = Zlib.crc32("General") % CoPlan::PlansHelper::PLAN_TYPE_COLOR_COUNT
      expect(response.body).to include("plan-type-icon--#{tint}")
    end
  end

  describe "content preview on rows" do
    it "renders a markdown-stripped preview when there is no AI summary" do
      plan.current_plan_version.update!(content_markdown: "# Heading\n\nThis is the **plan body** with [links](https://example.com).")
      get library_page_path(alice)
      expect(response.body).to include("plan-row__summary")
      expect(response.body).to include("This is the plan body with links")
      expect(response.body).not_to include("**plan body**")
    end

    it "omits the summary line when the plan has no content" do
      plan.current_plan_version.update_columns(content_markdown: "", content_sha256: Digest::SHA256.hexdigest(""))
      get library_page_path(alice)
      expect(response.body).not_to include("plan-row__summary")
    end
  end

  it "can view brainstorm plan as non-author" do
    sign_in_as(bob)
    get plan_page_path(brainstorm_plan)
    expect(response).to have_http_status(:ok)
  end

  describe "onboarding banner" do
    it "shows banner when user has no plans" do
      sign_in_as(bob)
      get library_page_path(alice)
      expect(response.body).to include("onboarding-banner")
    end

    it "hides banner when user has created a plan" do
      plan # alice has a plan
      get library_page_path(alice)
      expect(response.body).not_to include("onboarding-banner")
    end

    it "hides banner when onboarding_banner config is nil" do
      sign_in_as(bob)
      original = CoPlan.configuration.onboarding_banner
      CoPlan.configuration.onboarding_banner = nil
      get library_page_path(alice)
      expect(response.body).not_to include("onboarding-banner")
      CoPlan.configuration.onboarding_banner = original
    end

    it "displays custom banner text from configuration" do
      sign_in_as(bob)
      original = CoPlan.configuration.onboarding_banner
      CoPlan.configuration.onboarding_banner = "Custom onboarding message"
      get library_page_path(alice)
      expect(response.body).to include("Custom onboarding message")
      CoPlan.configuration.onboarding_banner = original
    end
  end

  describe "folder filtering" do
    let!(:root) { create(:folder, name: "Team EBT", created_by_user: alice) }
    let!(:sub) { create(:folder, name: "Q3", parent: root, created_by_user: alice) }
    let!(:root_plan) { create(:plan, :considering, created_by_user: alice, title: "Root Level Plan") }
    let!(:sub_plan) { create(:plan, :considering, created_by_user: alice, title: "Subfolder Plan") }
    let!(:loose_plan) { create(:plan, :considering, created_by_user: alice, title: "Unfiled Plan") }

    before do
      CoPlan::Plans::Place.call(plan: root_plan, folder: root, actor: alice)
      CoPlan::Plans::Place.call(plan: sub_plan, folder: sub, actor: alice)
    end

    it "shows the folder's own docs and subfolders at that level" do
      get folder_page_path(root)
      expect(response.body).to include("Root Level Plan")
      expect(response.body).to include("Q3") # subfolder row, one click away
      expect(response.body).not_to include("Subfolder Plan")
      expect(response.body).not_to include("Unfiled Plan")
    end

    it "covers the folder's whole subtree when a filter narrows the view" do
      root_plan.tag_names = [ "infra" ]
      sub_plan.tag_names = [ "infra" ]

      get folder_page_path(root, tag: "infra")
      expect(response.body).to include("Root Level Plan")
      expect(response.body).to include("Subfolder Plan")
      expect(response.body).not_to include("Unfiled Plan")
    end

    it "filters to a leaf folder only" do
      get folder_page_path(sub)
      expect(response.body).to include("Subfolder Plan")
      expect(response.body).not_to include("Root Level Plan")
    end

    it "shows the folder trail as breadcrumbs, not a filter chip" do
      get folder_page_path(sub)
      expect(response.body).to include("workspace-crumbs")
      expect(response.body).to include("My Plans")
      expect(response.body).to include("Team EBT")
      expect(response.body).to match(/aria-current="location"[^>]*>Q3|Q3<[^>]*aria-current/)
      expect(response.body).not_to include("Folder: Team EBT")
    end

    it "combines a folder with a tag filter" do
      root_plan.tag_names = [ "infra" ]
      sub_plan.tag_names = [ "frontend" ]
      also_infra = create(:plan, :considering, created_by_user: alice, title: "Second Infra Plan")
      CoPlan::Plans::Place.call(plan: also_infra, folder: root, actor: alice)
      also_infra.tag_names = [ "infra" ]

      get folder_page_path(root, tag: "infra")
      expect(response.body).to include("Root Level Plan")
      expect(response.body).to include("Second Infra Plan")
      expect(response.body).not_to include("Subfolder Plan")
    end

    it "renders a folder-specific empty state" do
      empty = create(:folder, name: "Empty Folder", created_by_user: alice)
      get folder_page_path(empty)
      expect(response.body).to include("empty-state")
      expect(response.body).to include("Empty Folder")
    end

    it "shows the filing location on rows in flat results" do
      sub_plan.tag_names = [ "infra" ]
      get library_page_path(alice, tag: "infra")
      expect(response.body).to include("Team EBT/Q3")
    end

    # A folder is a place with an address, so a folder that's gone is a path
    # that names nothing rather than a stale param to recover from.
    it "404s when the folder no longer exists" do
      get "#{library_page_path(alice)}/gone?tag=infra"
      expect(response).to have_http_status(:not_found)
    end

    it "pages a folder's level view past the first 20 without losing the folder scope" do
      21.times do |i|
        p = create(:plan, :considering, created_by_user: alice, title: "Paged Plan #{format('%02d', i)}")
        CoPlan::Plans::Place.call(plan: p, folder: root, actor: alice)
        p.update_columns(updated_at: (i + 1).hours.ago)
      end
      root_plan.update_columns(updated_at: 2.days.ago) # oldest, lands on page 2

      get folder_page_path(root)
      expect(response.body).to include("Paged Plan 00")
      expect(response.body).not_to include("Root Level Plan")
      # The lazy next-page frame must carry the folder, or page 2 would
      # silently fall back to the whole workspace. It carries it in the path.
      expect(response.body).to include("page=2")
      expect(response.body).to include(browse_path(handle: alice.library.handle, slug_path: "team-ebt"))

      get folder_page_path(root, group: "level", page: 2),
        headers: { "Turbo-Frame" => "plans-level-page-2" }
      expect(response.body).to include("Root Level Plan")
      expect(response.body).to include("Paged Plan 20")
      expect(response.body).not_to include("Paged Plan 00")
      expect(response.body).not_to include("Subfolder Plan") # still level-scoped
    end

    it "clamps a non-positive page param instead of erroring" do
      get library_page_path(alice, filter: "published", page: "0")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Root Level Plan")
    end
  end

  describe "sidebar" do
    it "renders the folder tree with visible-plan counts" do
      folder = create(:folder, name: "Infra", created_by_user: alice)
      CoPlan::Plans::Place.call(plan: create(:plan, :considering, created_by_user: alice), folder: folder, actor: alice)
      get library_page_path(alice)
      expect(response.body).to include("folder-tree")
      expect(response.body).to include("Infra")
    end

    # The sidebar belongs to the library on screen, so browsing someone
    # else's page never mixes their shelves into yours.
    it "shows the browsed library's folders, not the viewer's" do
      folder = create(:folder, name: "Secret Stash", created_by_user: bob)
      CoPlan::Plans::Place.call(plan: create(:plan, :draft, created_by_user: bob), folder: folder, actor: bob)

      sign_in_as(alice)
      get library_page_path(alice)
      expect(response.body).not_to include("Secret Stash")

      # Bob's own draft counts on his own page; it stays invisible to alice.
      sign_in_as(bob)
      get library_page_path(bob)
      expect(response.body).to match(%r{Secret Stash</span>\s*<span class="sidebar__count">1</span>})

      sign_in_as(alice)
      get library_page_path(bob)
      expect(response.body).to match(%r{Secret Stash</span>\s*<span class="sidebar__count">0</span>})
    end

    it "counts the plans filed in a folder" do
      folder = create(:folder, name: "My Corner", created_by_user: alice)
      CoPlan::Plans::Place.call(plan: create(:plan, :considering, created_by_user: alice), folder: folder, actor: alice)

      get library_page_path(alice)
      expect(response.body).to match(%r{My Corner</span>\s*<span class="sidebar__count">1</span>})
    end

    it "includes subfolder plans in parent folder counts" do
      root = create(:folder, name: "Team EBT", created_by_user: alice)
      sub = create(:folder, name: "Q3", parent: root, created_by_user: alice)
      CoPlan::Plans::Place.call(plan: create(:plan, :considering, created_by_user: alice), folder: sub, actor: alice)
      get library_page_path(alice)
      expect(response.body).to match(%r{Team EBT</span>\s*<span class="sidebar__count">1</span>})
    end

    it "does not surface tags used only on other users' brainstorms" do
      secret = create(:plan, :brainstorm, created_by_user: bob)
      secret.tag_names = [ "secret-tag" ]
      visible = create(:plan, :considering, created_by_user: bob)
      visible.tag_names = [ "public-tag" ]

      get library_page_path(bob)
      expect(response.body).to include("public-tag")
      expect(response.body).not_to include("secret-tag")
    end

    it "scopes sidebar tags to the library being browsed" do
      others = create(:plan, :considering, created_by_user: bob)
      others.tag_names = [ "bobs-tag" ]

      get library_page_path(alice)
      expect(response.body).not_to include("bobs-tag")
    end

    it "shows a New folder form" do
      get library_page_path(alice)
      expect(response.body).to include("New folder")
      expect(response.body).to include('action="/_/folders"')
    end

    it "scopes tag counts to the current folder" do
      payments = create(:folder, name: "Payments", created_by_user: alice)
      2.times do |i|
        loose = create(:plan, :considering, created_by_user: alice, title: "Loose #{i}")
        loose.tag_names = [ "kmp" ]
      end

      get library_page_path(alice)
      expect(response.body).to match(%r{#kmp</span>\s*<span class="sidebar__count">2</span>})

      # Inside an empty folder no plans match — the tag disappears rather
      # than advertising a count that clicking can't produce.
      get folder_page_path(payments)
      expect(response.body).not_to include("#kmp")
    end

    it "counts the updated windows combinatorially and drops empty ones" do
      fresh = create(:plan, :considering, created_by_user: alice, title: "Fresh One")
      fresh.tag_names = [ "infra" ]
      stale = create(:plan, :considering, created_by_user: alice, title: "Stale One")
      stale.tag_names = [ "legacy" ]
      stale.update_columns(updated_at: 2.months.ago)

      get library_page_path(alice)
      expect(response.body).to match(%r{Last 7 days</span>\s*<span class="sidebar__count">1</span>})

      # Under a tag whose only plan is months old the windows would show 0 —
      # they drop out instead, like tags and types do.
      get library_page_path(alice, tag: "legacy")
      expect(response.body).not_to include("Last 7 days")
    end

    it "scopes folder counts to the Hidden filter — count = what clicking shows" do
      folder = create(:folder, name: "Mixed", created_by_user: alice)
      active = create(:plan, :considering, created_by_user: alice)
      buried = create_list(:plan, 2, :archived, created_by_user: alice)
      ([ active ] + buried).each do |p|
        CoPlan::Plans::Place.call(plan: p, folder: folder, actor: alice)
      end

      # WORKSPACE_LINK_PARAMS carries :filter, so a sidebar folder link
      # keeps the archived filter — its count must match that destination.
      get library_page_path(alice)
      expect(response.body).to match(%r{Mixed</span>\s*<span class="sidebar__count">1</span>})

      get library_page_path(alice, filter: "archived")
      expect(response.body).to match(%r{Mixed</span>\s*<span class="sidebar__count">2</span>})
    end

    it "lists document types with counts scoped to the other active filters" do
      rfc = create(:plan_type, name: "RFC", icon: "scroll")
      design = create(:plan_type, name: "Design Doc", icon: "pen-tool")
      tagged = create(:plan, :considering, created_by_user: alice, plan_type: rfc)
      tagged.tag_names = [ "infra" ]
      create(:plan, :considering, created_by_user: alice, plan_type: design)

      get library_page_path(alice)
      expect(response.body).to match(%r{RFC</span>\s*<span class="sidebar__count">1</span>})
      expect(response.body).to match(%r{Design Doc</span>\s*<span class="sidebar__count">1</span>})

      # Under the tag filter only the RFC matches; Design Doc drops out
      # instead of showing a dead count.
      get library_page_path(alice, tag: "infra")
      expect(response.body).to match(%r{RFC</span>\s*<span class="sidebar__count">1</span>})
      expect(response.body).not_to include("Design Doc")
    end
  end

  describe "updated-window filter" do
    it "narrows to recently updated plans and shows a clearable chip" do
      fresh = create(:plan, :considering, created_by_user: alice, title: "Fresh Plan")
      stale = create(:plan, :considering, created_by_user: alice, title: "Stale Plan")
      stale.update_columns(updated_at: 2.months.ago)

      get library_page_path(alice, updated: "7d")
      expect(response).to have_http_status(:success)
      expect(response.body).to include(fresh.title)
      expect(response.body).not_to include(stale.title)
      expect(response.body).to include("Updated: last 7 days")
    end

    it "offers 7 and 30 day windows in the sidebar when they'd show something" do
      plan # a fresh plan matches both windows
      get library_page_path(alice)
      expect(response.body).to include("Last 7 days")
      expect(response.body).to include("Last 30 days")
    end

    it "ignores unknown window values" do
      plan
      get library_page_path(alice, updated: "9999d")
      expect(response).to have_http_status(:success)
      expect(response.body).to include(plan.title)
      expect(response.body).not_to include("Updated: last")
    end
  end

  describe "needs attention strip" do
    it "lists plans with unread comments for the current user" do
      thread = create(:comment_thread, plan: plan, created_by_user: bob)
      notification = create(:notification, user: alice, plan: plan, comment_thread: thread)

      get library_page_path(alice)
      expect(response.body).to include("Needs attention (1)")
      expect(response.body).to include("1 unread comment")
      attention_link = Nokogiri::HTML(response.body).at_css(".attention__link")
      expect(attention_link["href"]).to eq(notification_path(notification))
      expect(attention_link["data-turbo"]).to eq("false")
    end

    it "links resolved unread comments through their notification deep link" do
      thread = create(:comment_thread, :resolved, plan: plan, created_by_user: bob)
      notification = create(:notification, user: alice, plan: plan, comment_thread: thread)

      get library_page_path(alice)

      expect(response.body).to include(notification_path(notification))
      expect(response.body).not_to include(%(href="#{plan_path(plan)}" class="attention__link"))
    end

    it "is omitted when nothing is unread" do
      plan # visible plan, no notifications
      get library_page_path(alice)
      expect(response.body).not_to include("Needs attention")
    end

    it "never resurfaces an archived plan through stale notifications" do
      archived = create(:plan, :archived, created_by_user: alice, title: "Buried Plan")
      thread = create(:comment_thread, plan: archived, created_by_user: bob)
      create(:notification, user: alice, plan: archived, comment_thread: thread)

      get library_page_path(alice)
      expect(response.body).not_to include("Buried Plan")
    end

    it "never leaks another user's draft title through notifications" do
      bobs_draft = create(:plan, :draft, created_by_user: bob, title: "Bobs Secret Draft")
      thread = create(:comment_thread, plan: bobs_draft, created_by_user: bob)
      create(:notification, user: alice, plan: bobs_draft, comment_thread: thread)

      get library_page_path(alice)
      expect(response.body).not_to include("Bobs Secret Draft")
    end

    # A pagination frame renders rows and returns before the strip, so it
    # should pay for the grouped badge count and nothing more.
    it "is not built for a pagination frame" do
      thread = create(:comment_thread, plan: plan, created_by_user: bob)
      create(:notification, user: alice, plan: plan, comment_thread: thread)

      expect(CoPlan::Notifications::NeedsAttention).not_to receive(:call)

      get library_page_path(alice, group: "level", page: 1), headers: { "Turbo-Frame" => "plans-level-page-1" }

      expect(response).to have_http_status(:success)
      expect(response.body).to include("1")
    end

    it "offers a per-plan clear so the strip can be emptied without reading" do
      thread = create(:comment_thread, plan: plan, created_by_user: bob)
      create(:notification, user: alice, plan: plan, comment_thread: thread)

      get library_page_path(alice)

      clear_form = Nokogiri::HTML(response.body).at_css(".attention__clear-form")
      expect(clear_form["action"]).to eq(mark_plan_read_notifications_path(plan_id: plan.id))
    end
  end

  # The main way the strip empties: you go look at the plan.
  describe "opening a plan clears its notifications" do
    let(:thread) { create(:comment_thread, plan: plan, created_by_user: bob) }

    it "marks the viewer's unread rows for that plan read" do
      first = create(:notification, user: alice, plan: plan, comment_thread: thread)
      second = create(:notification, user: alice, plan: plan, comment_thread: thread, reason: "agent_response")

      get plan_page_path(plan)

      expect(response).to have_http_status(:success)
      expect(first.reload.read_at).to be_present
      expect(second.reload.read_at).to be_present
    end

    it "renders the bell already cleared, not a stale count" do
      create(:notification, user: alice, plan: plan, comment_thread: thread)

      get plan_page_path(plan)

      badge = Nokogiri::HTML(response.body).at_css("#inbox-badge")
      expect(badge.text).to eq("0")
      expect(badge["class"]).to include("inbox-badge--hidden")
    end

    it "leaves rows for other plans alone" do
      other_plan = create(:plan, :considering, created_by_user: alice)
      other_thread = create(:comment_thread, plan: other_plan, created_by_user: bob)
      other = create(:notification, user: alice, plan: other_plan, comment_thread: other_thread)

      get plan_page_path(plan)

      expect(other.reload.read_at).to be_nil
    end

    it "leaves other people's rows for the same plan alone" do
      bobs = create(:notification, user: bob, plan: plan, comment_thread: thread)

      get plan_page_path(plan)

      expect(bobs.reload.read_at).to be_nil
    end

    it "does not clear anything on the history page" do
      notification = create(:notification, user: alice, plan: plan, comment_thread: thread)

      get plan_history_page_path(plan)

      expect(notification.reload.read_at).to be_nil
    end

    # Workspace rows prefetch on hover, so this GET fires for a cursor
    # passing over a row. Nobody has looked at anything yet.
    it "ignores a Turbo hover prefetch" do
      notification = create(:notification, user: alice, plan: plan, comment_thread: thread)

      get plan_page_path(plan), headers: { "X-Sec-Purpose" => "prefetch" }

      expect(response).to have_http_status(:success)
      expect(notification.reload.read_at).to be_nil
    end

    it "does not advance the last-seen mark on a prefetch either" do
      get plan_page_path(plan), headers: { "X-Sec-Purpose" => "prefetch" }

      expect(CoPlan::PlanViewer.where(plan: plan, user: alice)).not_to exist
    end
  end

  describe "PATCH /plans/:id/move_to_folder" do
    let(:folder) { create(:folder, name: "Infra", created_by_user: alice) }

    def alice_placement
      alice.library.placements.find_by(plan_id: plan.id)
    end

    it "shelves the author's plan and logs an event" do
      expect {
        patch move_to_folder_plan_path(plan), params: { folder_id: folder.id }
      }.to change(CoPlan::PlanEvent, :count).by(1)
      expect(response).to redirect_to(library_page_path(alice))
      expect(flash[:notice]).to include("Infra")
      expect(alice_placement.folder).to eq(folder)

      event = CoPlan::PlanEvent.order(:created_at).last
      expect(event.event_type).to eq("moved_to_folder")
      expect(event.after_value).to eq("Infra")
    end

    it "responds with JSON for the drag-and-drop controller" do
      patch move_to_folder_plan_path(plan),
        params: { folder_id: folder.id }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body)
      expect(body["folder_id"]).to eq(folder.id)
      expect(body["folder_path"]).to eq("Infra")
      expect(body["message"]).to include("Infra")
    end

    it "unfiles with a blank folder_id" do
      CoPlan::Plans::Place.call(plan: plan, folder: folder, actor: alice)
      patch move_to_folder_plan_path(plan), params: { folder_id: "" }
      expect(alice_placement).to be_nil
    end

    # A plan has one home, so filing someone else's published plan into
    # your own library would be taking it, not bookmarking it.
    it "refuses to move someone else's plan into your library" do
      bobs_folder = create(:folder, name: "Bobs Shelf", created_by_user: bob)
      sign_in_as(bob)

      patch move_to_folder_plan_path(plan), params: { folder_id: bobs_folder.id }

      expect(CoPlan::PlanPlacement.where(plan_id: plan.id)).to be_empty
    end

    it "refuses to file someone else's unlisted draft, even with the URL in hand" do
      bobs_draft = create(:plan, :draft, created_by_user: bob)

      patch move_to_folder_plan_path(bobs_draft),
        params: { folder_id: folder.id }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(alice.library.placements.where(plan_id: bobs_draft.id)).to be_empty

      patch move_to_folder_plan_path(bobs_draft), params: { folder_id: folder.id }
      expect(flash[:alert]).to be_present
      expect(alice.library.placements.where(plan_id: bobs_draft.id)).to be_empty
    end

    it "rejects shelving into someone else's folder" do
      bobs_folder = create(:folder, name: "Bobs Shelf", created_by_user: bob)
      patch move_to_folder_plan_path(plan), params: { folder_id: bobs_folder.id }
      # Not in alice's library, so it reads as unknown.
      expect(flash[:alert]).to include("Unknown folder")
      expect(alice_placement).to be_nil
    end

    it "rejects an unknown folder" do
      patch move_to_folder_plan_path(plan),
        params: { folder_id: "nope" }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "does not log an event for a no-op move" do
      CoPlan::Plans::Place.call(plan: plan, folder: folder, actor: alice)
      expect {
        patch move_to_folder_plan_path(plan), params: { folder_id: folder.id }
      }.not_to change(CoPlan::PlanEvent, :count)
    end

    it "renders rows draggable, with no per-row save control" do
      plan # alice's plan
      get library_page_path(alice)
      rows = response.body.scan(/<article class="plan-row"[^>]*>/)
      # Dragging a row moves the document, so it needs no destination
      # chooser — the sidebar is the drop target.
      expect(rows.find { |r| r.include?(plan.id) }).to include('draggable="true"')
      # No per-row bookmark (and so no navigator popover) on the workspace:
      # rows file via drag & drop; the plan page's title bookmark is the
      # click path.
      expect(response.body).not_to include("plan-row__save")
      expect(response.body).not_to include('id="folder-picker-modal"')
    end
  end

  describe "POST /folders (web)" do
    it "creates a folder and filters to it" do
      post folders_path, params: { folder: { name: "Team EBT" } }
      folder = CoPlan::Folder.find_by(name: "Team EBT")
      expect(folder).to be_present
      expect(folder.created_by_user).to eq(alice)
      expect(response).to redirect_to(folder_page_path(folder))
    end

    it "creates a nested folder" do
      parent = create(:folder, name: "Team EBT", created_by_user: alice)
      post folders_path, params: { folder: { name: "Q3", parent_id: parent.id } }
      expect(CoPlan::Folder.find_by(name: "Q3").parent).to eq(parent)
    end

    it "surfaces validation errors via flash" do
      create(:folder, name: "Team EBT", created_by_user: alice)
      post folders_path, params: { folder: { name: "Team EBT" } }
      expect(flash[:alert]).to include("Couldn't create folder")
    end

    it "rejects an unknown parent instead of creating a root folder" do
      post folders_path, params: { folder: { name: "Q3", parent_id: "gone" } }
      expect(CoPlan::Folder.find_by(name: "Q3")).to be_nil
      expect(flash[:alert]).to include("parent folder no longer exists")
    end
  end

  describe "PATCH /folders/:id (web reparenting)" do
    let!(:team) { create(:folder, name: "Team EBT", created_by_user: alice) }
    let!(:q3) { create(:folder, name: "Q3", created_by_user: alice) }

    def reparent(folder, parent_id)
      patch folder_path(folder), params: { parent_id: parent_id }, as: :json
    end

    it "nests a folder under another" do
      reparent(q3, team.id)
      expect(response).to have_http_status(:ok)
      expect(q3.reload.parent).to eq(team)
      expect(response.parsed_body["path"]).to eq("Team EBT/Q3")
    end

    it "promotes a folder to top level with a blank parent" do
      q3.update!(parent: team)
      reparent(q3, "")
      expect(response).to have_http_status(:ok)
      expect(q3.reload.parent).to be_nil
    end

    it "rejects nesting a folder inside its own subtree" do
      q3.update!(parent: team)
      reparent(team, q3.id)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("subfolders")
      expect(team.reload.parent).to be_nil
    end

    it "rejects moves that would exceed the depth cap" do
      mid = create(:folder, name: "Mid", parent: team, created_by_user: alice)
      leaf = create(:folder, name: "Leaf", parent: mid, created_by_user: alice)
      reparent(q3, leaf.id)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("depth")
      expect(q3.reload.parent).to be_nil
    end

    it "cannot touch folders in someone else's library" do
      bobs = create(:folder, name: "Bobs Folder", created_by_user: bob)
      reparent(bobs, team.id)
      expect(response).to have_http_status(:not_found)
      expect(bobs.reload.parent).to be_nil
    end

    it "rejects an unknown destination folder" do
      reparent(q3, "gone")
      expect(response).to have_http_status(:unprocessable_content)
      expect(q3.reload.parent).to be_nil
    end
  end
end
