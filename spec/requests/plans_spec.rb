require "rails_helper"

RSpec.describe "Plans", type: :request do
  let(:alice) { create(:coplan_user, :admin) }
  let(:bob) { create(:coplan_user) }
  let(:plan) { create(:plan, :considering, created_by_user: alice) }
  let(:brainstorm_plan) { create(:plan, :brainstorm, created_by_user: alice) }

  before { sign_in_as(alice) }

  it "index shows plans" do
    plan # trigger creation
    get plans_path
    expect(response).to have_http_status(:success)
    expect(response.body).to include(plan.title)
  end

  it "index filters by status" do
    plan # trigger creation
    get plans_path(status: "considering")
    expect(response).to have_http_status(:success)
    expect(response.body).to include(plan.title)
  end

  it "index filters to my plans" do
    plan # created by alice
    bobs_plan = create(:plan, :considering, created_by_user: bob)
    get plans_path(scope: "mine")
    expect(response).to have_http_status(:success)
    expect(response.body).to include(plan.title)
    expect(response.body).not_to include(bobs_plan.title)
  end

  it "index filters by tag" do
    plan.tag_names = [ "infra" ]
    other = create(:plan, :considering, created_by_user: alice, title: "Other Plan")
    other.tag_names = [ "frontend" ]
    get plans_path(tag: "infra")
    expect(response).to have_http_status(:success)
    expect(response.body).to include(plan.title)
    expect(response.body).not_to include("Other Plan")
  end

  it "index shows tag badges on plan cards" do
    plan.tag_names = [ "infra", "api" ]
    get plans_path
    expect(response.body).to include("badge--tag")
    expect(response.body).to include("infra")
    expect(response.body).to include("api")
  end

  it "index shows active tag filter bar" do
    plan.tag_names = [ "infra" ]
    get plans_path(tag: "infra")
    expect(response.body).to include("active-filter")
    expect(response.body).to include("infra")
    expect(response.body).to include("Clear")
  end

  it "show plan renders tag badges in header" do
    plan.tag_names = [ "infra", "security" ]
    get plan_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include("badge--tag")
    expect(response.body).to include("infra")
    expect(response.body).to include("security")
  end

  it "show plan renders successfully" do
    get plan_path(plan)
    expect(response).to have_http_status(:success)
  end

  it "show plan renders plan content" do
    get plan_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include("plan-layout__content")
  end

  it "scopes comment footnote ids so they can't collide with the plan body's" do
    thread = create(:comment_thread, :with_anchor, plan: plan, plan_version: plan.current_plan_version, created_by_user: alice)
    comment = create(:comment, comment_thread: thread, author_type: "human", author_id: alice.id,
                     body_markdown: "Noted.[^1]\n\n[^1]: A comment footnote.")

    get plan_path(plan)
    expect(response.body).to include(%(id="comment-#{comment.id}-fn-1"))
    expect(response.body).to include(%(href="#comment-#{comment.id}-fn-1"))
  end

  it "show plan renders content navigation sidebar" do
    get plan_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include('class="content-nav"')
    expect(response.body).to include('data-coplan--content-nav-target="sidebar"')
    expect(response.body).to include('data-coplan--content-nav-target="list"')
    expect(response.body).to include("content-nav-show-btn")
  end

  it "show plan wires up both text-selection and content-nav controllers" do
    get plan_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include('data-controller="coplan--text-selection coplan--content-nav coplan--checkbox"')
  end

  it "show plan shares content target between controllers" do
    get plan_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include('data-coplan--content-nav-target="content"')
    expect(response.body).to include('data-coplan--text-selection-target="content"')
  end

  it "show plan without content does not render content nav sidebar" do
    empty_plan = create(:plan, :considering, created_by_user: alice)
    empty_plan.current_plan_version.update_columns(content_markdown: "", content_sha256: Digest::SHA256.hexdigest(""))
    get plan_path(empty_plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include("empty-state")
    expect(response.body).not_to include('class="content-nav"')
  end

  it "show plan includes Open Graph meta tags" do
    get plan_path(plan)
    expect(response.body).to include('property="og:title"')
    expect(response.body).to include('property="og:description"')
    expect(response.body).to include('property="og:site_name"')
    expect(response.body).to include('name="twitter:card"')
  end

  it "show plan includes turbo stream subscription" do
    get plan_path(plan)
    expect(response).to have_http_status(:success)
    expect(response.body).to include("turbo-cable-stream-source")
  end

  it "edit plan" do
    get edit_plan_path(plan)
    expect(response).to have_http_status(:success)
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
    expect(response).to redirect_to(plan_path(plan))
  end

  it "index hides other users brainstorm plans on the All scope" do
    brainstorm_plan # alice's brainstorm
    sign_in_as(bob)
    get plans_path(scope: "all")
    expect(response).to have_http_status(:success)
    expect(response.body).not_to include(brainstorm_plan.title)
  end

  it "index shows own brainstorm plans" do
    brainstorm_plan # alice's brainstorm
    get plans_path
    expect(response).to have_http_status(:success)
    expect(response.body).to include(brainstorm_plan.title)
  end

  describe "default scope" do
    it "defaults to 'mine' and hides other users' plans" do
      plan # alice's
      bobs_plan = create(:plan, :considering, created_by_user: bob, title: "Bobs Roadmap")
      get plans_path
      expect(response.body).to include(plan.title)
      expect(response.body).not_to include(bobs_plan.title)
    end

    it "scope=all shows everyone's published plans" do
      plan # alice's
      bobs_plan = create(:plan, :considering, created_by_user: bob, title: "Bobs Roadmap")
      get plans_path(scope: "all")
      expect(response.body).to include(plan.title)
      expect(response.body).to include(bobs_plan.title)
    end

    it "groups plans into collapsible visibility groups, published work first" do
      create(:plan, :published, created_by_user: alice, title: "Published Plan")
      create(:plan, :draft,     created_by_user: alice, title: "Draft Plan")
      get plans_path
      expect(response.body).to include("plan-group")
      expect(response.body.index("Published Plan")).to be < response.body.index("Draft Plan")
    end

    it "marks the draft group as collapsed by default" do
      create(:plan, :draft, created_by_user: alice)
      create(:plan, :published, created_by_user: alice)
      get plans_path
      draft_group = response.body[/<section class="plan-group"[^>]*data-group-key="draft"[^>]*>/]
      published_group = response.body[/<section class="plan-group"[^>]*data-group-key="published"[^>]*>/]
      expect(draft_group).to include("data-default-collapsed")
      expect(published_group).not_to include("data-default-collapsed")
    end

    it "omits groups with no plans" do
      create(:plan, :published, created_by_user: alice)
      get plans_path
      expect(response.body).to include('data-group-key="published"')
      expect(response.body).not_to include('data-group-key="draft"')
    end

    # COPLAN-32 successor: every status gets its own group with its own
    # pagination, so the author's brainstorms always render on the first
    # page load no matter how many active plans exist.
    it "surfaces the author's own brainstorms on the first page despite many active plans" do
      brainstorm = create(:plan, :brainstorm, created_by_user: alice, title: "Buried Brainstorm")
      create_list(:plan, CoPlan::PlansController::PER_PAGE + 5, :developing, created_by_user: alice)
      get plans_path
      expect(response).to have_http_status(:success)
      expect(response.body).to include(brainstorm.title)
    end

    it "paginates within a group via a group-scoped lazy frame" do
      create_list(:plan, CoPlan::PlansController::PER_PAGE + 2, :published, created_by_user: alice)
      get plans_path
      expect(response.body).to include('id="plans-published-page-2"')
      expect(response.body).to include("group=published")
    end

    it "renders a flat list when filtered to a single group" do
      create(:plan, :published, created_by_user: alice, title: "Published Plan")
      get plans_path(filter: "published")
      expect(response.body).not_to include("plan-group__toggle")
      expect(response.body).to include("Published Plan")
    end

    it "scope=all groups everyone's visible plans" do
      create(:plan, :published, created_by_user: bob, title: "Bobs Published Plan")
      get plans_path(scope: "all")
      expect(response.body).to include('data-group-key="published"')
      expect(response.body).to include("Bobs Published Plan")
    end
  end

  describe "content preview on rows" do
    it "renders a markdown-stripped preview when there is no AI summary" do
      plan.current_plan_version.update!(content_markdown: "# Heading\n\nThis is the **plan body** with [links](https://example.com).")
      get plans_path
      expect(response.body).to include("plan-row__summary")
      expect(response.body).to include("This is the plan body with links")
      expect(response.body).not_to include("**plan body**")
    end

    it "omits the summary line when the plan has no content" do
      plan.current_plan_version.update_columns(content_markdown: "", content_sha256: Digest::SHA256.hexdigest(""))
      get plans_path
      expect(response.body).not_to include("plan-row__summary")
    end
  end

  it "can view brainstorm plan as non-author" do
    sign_in_as(bob)
    get plan_path(brainstorm_plan)
    expect(response).to have_http_status(:ok)
  end

  describe "onboarding banner" do
    it "shows banner when user has no plans" do
      sign_in_as(bob)
      get plans_path
      expect(response.body).to include("onboarding-banner")
    end

    it "hides banner when user has created a plan" do
      plan # alice has a plan
      get plans_path
      expect(response.body).not_to include("onboarding-banner")
    end

    it "hides banner when onboarding_banner config is nil" do
      sign_in_as(bob)
      original = CoPlan.configuration.onboarding_banner
      CoPlan.configuration.onboarding_banner = nil
      get plans_path
      expect(response.body).not_to include("onboarding-banner")
      CoPlan.configuration.onboarding_banner = original
    end

    it "displays custom banner text from configuration" do
      sign_in_as(bob)
      original = CoPlan.configuration.onboarding_banner
      CoPlan.configuration.onboarding_banner = "Custom onboarding message"
      get plans_path
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

    it "filters to a folder including its subfolders" do
      get plans_path(folder: root.id)
      expect(response.body).to include("Root Level Plan")
      expect(response.body).to include("Subfolder Plan")
      expect(response.body).not_to include("Unfiled Plan")
    end

    it "filters to a leaf folder only" do
      get plans_path(folder: sub.id)
      expect(response.body).to include("Subfolder Plan")
      expect(response.body).not_to include("Root Level Plan")
    end

    it "shows a clearable folder filter chip" do
      get plans_path(folder: root.id)
      expect(response.body).to include("Folder: Team EBT")
      expect(response.body).to include("Clear all")
    end

    it "combines folder with tag and scope filters" do
      root_plan.tag_names = [ "infra" ]
      sub_plan.tag_names = [ "frontend" ]
      bobs_plan = create(:plan, :considering, created_by_user: bob, title: "Bobs Foldered Plan")
      # Alice shelves Bob's plan in her own folder — it joins her workspace.
      CoPlan::Plans::Place.call(plan: bobs_plan, folder: root, actor: alice)
      bobs_plan.tag_names = [ "infra" ]

      get plans_path(folder: root.id, tag: "infra", scope: "all")
      expect(response.body).to include("Root Level Plan")
      expect(response.body).to include("Bobs Foldered Plan")
      expect(response.body).not_to include("Subfolder Plan")
    end

    it "renders a folder-specific empty state" do
      empty = create(:folder, name: "Empty Folder", created_by_user: alice)
      get plans_path(folder: empty.id)
      expect(response.body).to include("empty-state")
      expect(response.body).to include("Empty Folder")
    end

    it "shows folder breadcrumbs on rows" do
      get plans_path
      expect(response.body).to include("Team EBT/Q3")
    end

    it "redirects with an alert when the folder no longer exists" do
      get plans_path(folder: "gone", tag: "infra")
      expect(response).to redirect_to(plans_path(tag: "infra"))
      expect(flash[:alert]).to include("no longer exists")
    end

    it "clamps a non-positive page param instead of erroring" do
      get plans_path(status: "considering", page: "0")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Root Level Plan")
    end
  end

  describe "sidebar" do
    it "renders the folder tree with visible-plan counts" do
      folder = create(:folder, name: "Infra", created_by_user: alice)
      CoPlan::Plans::Place.call(plan: create(:plan, :considering, created_by_user: alice), folder: folder, actor: alice)
      get plans_path
      expect(response.body).to include("folder-tree")
      expect(response.body).to include("Infra")
    end

    it "shows only the viewer's own library in the sidebar" do
      folder = create(:folder, name: "Secret Stash", created_by_user: bob)
      CoPlan::Plans::Place.call(plan: create(:plan, :draft, created_by_user: bob), folder: folder, actor: bob)

      sign_in_as(alice)
      get plans_path(scope: "all")
      # Bob's folders are his library, not part of alice's workspace sidebar.
      expect(response.body).not_to include("Secret Stash")

      sign_in_as(bob)
      get plans_path(scope: "all")
      expect(response.body).to match(%r{Secret Stash</span>\s*<span class="sidebar__count">1</span>})
    end

    it "counts shelved plans in the viewer's workspace, whoever wrote them" do
      folder = create(:folder, name: "My Corner", created_by_user: alice)
      CoPlan::Plans::Place.call(plan: create(:plan, :considering, created_by_user: bob), folder: folder, actor: alice)

      # A placement makes the plan part of alice's workspace even in the
      # default "mine" scope — the shelf is hers.
      get plans_path
      expect(response.body).to match(%r{My Corner</span>\s*<span class="sidebar__count">1</span>})

      get plans_path(scope: "all")
      expect(response.body).to match(%r{My Corner</span>\s*<span class="sidebar__count">1</span>})
    end

    it "includes subfolder plans in parent folder counts" do
      root = create(:folder, name: "Team EBT", created_by_user: alice)
      sub = create(:folder, name: "Q3", parent: root, created_by_user: alice)
      CoPlan::Plans::Place.call(plan: create(:plan, :considering, created_by_user: alice), folder: sub, actor: alice)
      get plans_path
      expect(response.body).to match(%r{Team EBT</span>\s*<span class="sidebar__count">1</span>})
    end

    it "does not surface tags used only on other users' brainstorms" do
      secret = create(:plan, :brainstorm, created_by_user: bob)
      secret.tag_names = [ "secret-tag" ]
      visible = create(:plan, :considering, created_by_user: bob)
      visible.tag_names = [ "public-tag" ]

      get plans_path(scope: "all")
      expect(response.body).to include("public-tag")
      expect(response.body).not_to include("secret-tag")
    end

    it "scopes sidebar tags to the active workspace scope" do
      others = create(:plan, :considering, created_by_user: bob)
      others.tag_names = [ "bobs-tag" ]

      get plans_path
      expect(response.body).not_to include("bobs-tag")
    end

    it "shows a New folder form" do
      get plans_path
      expect(response.body).to include("New folder")
      expect(response.body).to include('action="/folders"')
    end
  end

  describe "needs attention strip" do
    it "lists plans with unread comments for the current user" do
      thread = create(:comment_thread, plan: plan, created_by_user: bob)
      create(:notification, user: alice, plan: plan, comment_thread: thread)

      get plans_path
      expect(response.body).to include("Needs attention (1)")
      expect(response.body).to include("1 unread comment")
    end

    it "is omitted when nothing is unread" do
      plan # visible plan, no notifications
      get plans_path
      expect(response.body).not_to include("Needs attention")
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
      expect(response).to redirect_to(plans_path)
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

    it "lets a non-author shelve a published plan in their own library" do
      bobs_folder = create(:folder, name: "Bobs Shelf", created_by_user: bob)
      sign_in_as(bob)

      expect {
        patch move_to_folder_plan_path(plan), params: { folder_id: bobs_folder.id }
      }.not_to change(CoPlan::PlanEvent, :count) # curating someone else's shelf isn't a plan event

      placement = bob.library.placements.find_by(plan_id: plan.id)
      expect(placement.folder).to eq(bobs_folder)
      # Alice's own library is untouched.
      expect(alice_placement).to be_nil
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

    it "renders drag handles and move menus on every row" do
      plan # alice's plan
      bobs_plan = create(:plan, :considering, created_by_user: bob, title: "Bobs Plan")
      get plans_path(scope: "all")
      rows = response.body.scan(/<article class="plan-row"[^>]*>/)
      alice_row = rows.find { |r| r.include?(plan.id) }
      bob_row = rows.find { |r| r.include?(bobs_plan.id) }
      # Anyone can shelve any visible plan into their own library.
      expect(alice_row).to include('draggable="true"')
      expect(bob_row).to include('draggable="true"')
    end
  end

  describe "POST /folders (web)" do
    it "creates a folder and filters to it" do
      post folders_path, params: { folder: { name: "Team EBT" } }
      folder = CoPlan::Folder.find_by(name: "Team EBT")
      expect(folder).to be_present
      expect(folder.created_by_user).to eq(alice)
      expect(response).to redirect_to(plans_path(folder: folder.id))
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
end
