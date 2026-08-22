require "rails_helper"

RSpec.describe CoPlan::Plans::AssignSlug do
  let(:author) { create(:coplan_user, username: "hampton") }
  let(:library) { author.library }

  def place(plan, folder)
    CoPlan::Plans::Place.call(plan: plan, folder: folder, actor: author)
    plan.reload
  end

  it "slugifies the title when there is nothing to strip" do
    plan = create(:plan, :published, created_by_user: author, title: "Q3 Orders Roadmap")

    expect(plan.slug).to eq("q3-orders-roadmap")
    expect(plan.url_path).to eq("hampton/q3-orders-roadmap")
  end

  it "drops the folder name the URL has already said" do
    folder = create(:folder, name: "LiveOrder", created_by_user: author)
    plan = create(:plan, :published, created_by_user: author, title: "LiveOrder Cart Roadmap")

    place(plan, folder)

    expect(plan.slug).to eq("cart-roadmap")
    expect(plan.url_path).to eq("hampton/liveorder/cart-roadmap")
  end

  it "matches the folder name regardless of how it was spaced" do
    folder = create(:folder, name: "Live Order", created_by_user: author)
    plan = create(:plan, :published, created_by_user: author, title: "LiveOrder Cart Roadmap")

    place(plan, folder)

    expect(plan.slug).to eq("cart-roadmap")
  end

  it "drops a trailing 'Plan', which says nothing in an app full of plans" do
    plan = create(:plan, :published, created_by_user: author, title: "Fulfillment API Migration Plan")

    expect(plan.slug).to eq("fulfillment-api-migration")
  end

  it "drops the library handle when the title repeats it" do
    plan = create(:plan, :published, created_by_user: author, title: "Hampton Pricing Notes")

    expect(plan.slug).to eq("pricing-notes")
  end

  it "keeps the full name rather than stripping to nothing" do
    folder = create(:folder, name: "LiveOrder", created_by_user: author)
    plan = create(:plan, :published, created_by_user: author, title: "LiveOrder")

    place(plan, folder)

    expect(plan.slug).to eq("liveorder")
    expect(plan.url_path).to eq("hampton/liveorder/liveorder")
  end

  it "re-derives the slug when the plan moves into a folder that renames it" do
    folder = create(:folder, name: "LiveOrder", created_by_user: author)
    plan = create(:plan, :published, created_by_user: author, title: "LiveOrder Cart Roadmap")
    expect(plan.slug).to eq("liveorder-cart-roadmap")

    place(plan, folder)

    expect(plan.slug).to eq("cart-roadmap")
  end

  describe "contested slugs" do
    it "gives the second plan a suffix and leaves the first one clean" do
      folder = create(:folder, name: "LiveOrder", created_by_user: author)
      first = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")
      second = create(:plan, :published, created_by_user: author, title: "LiveOrder Cart Roadmap")

      place(first, folder)
      place(second, folder)

      expect(first.slug_suffix).to be_nil
      expect(first.url_path).to eq("hampton/liveorder/cart-roadmap")
      expect(second.slug).to eq("cart-roadmap")
      expect(second.slug_suffix).to be_present
      expect(second.url_path).to match(%r{\Ahampton/liveorder/cart-roadmap~[a-z0-9]{4}\z})
    end

    it "leaves plans in different folders both clean" do
      here = create(:folder, name: "Here", created_by_user: author)
      there = create(:folder, name: "There", created_by_user: author)
      first = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")
      second = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")

      place(first, here)
      place(second, there)

      expect(first.slug_suffix).to be_nil
      expect(second.slug_suffix).to be_nil
    end

    # A folder wins the segment when both want it, so a plan sharing one
    # would have no address at all. The plan is the one that moves.
    it "steps around a sibling folder that already holds the segment" do
      create(:folder, name: "Roadmap", created_by_user: author)
      plan = create(:plan, :published, created_by_user: author, title: "Roadmap")

      expect(plan.slug).to eq("roadmap")
      expect(plan.slug_suffix).to be_present
      expect(plan.url_path).to match(%r{\Ahampton/roadmap~[a-z0-9]{4}\z})
    end

    it "only steps around folders at its own level" do
      parent = create(:folder, name: "Projects", created_by_user: author)
      create(:folder, name: "Roadmap", parent: parent, created_by_user: author)
      plan = create(:plan, :published, created_by_user: author, title: "Roadmap")

      expect(plan.slug_suffix).to be_nil
      expect(plan.url_path).to eq("hampton/roadmap")
    end

    # The other order: the plan was there first and the folder arrives. The
    # segment changes hands — anyone following the old link lands on the
    # folder that now owns that name, since a live page beats an alias —
    # but the document keeps an address of its own instead of losing one.
    it "re-slugs a plan a new folder would have shadowed" do
      plan = create(:plan, :published, created_by_user: author, title: "Roadmap")
      expect(plan.url_path).to eq("hampton/roadmap")

      folder = create(:folder, name: "Roadmap", created_by_user: author)

      expect(plan.reload.slug_suffix).to be_present
      expect(plan.url_path).not_to eq(folder.url_path)
      expect(CoPlan::Urls::Resolve.call(handle: "hampton", slug_path: plan.leaf_segment).plan).to eq(plan)
    end

    it "re-slugs a plan a folder rename would have shadowed" do
      plan = create(:plan, :published, created_by_user: author, title: "Roadmap")
      folder = create(:folder, name: "Plans", created_by_user: author)

      folder.update!(name: "Roadmap")

      expect(plan.reload.slug_suffix).to be_present
    end

    it "leaves a plan alone when the new folder is a level below it" do
      parent = create(:folder, name: "Projects", created_by_user: author)
      plan = create(:plan, :published, created_by_user: author, title: "Roadmap")

      create(:folder, name: "Roadmap", parent: parent, created_by_user: author)

      expect(plan.reload.slug_suffix).to be_nil
    end
  end

  describe "aliases" do
    it "records the old URL when a published plan is retitled" do
      plan = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")

      plan.update!(title: "Basket Roadmap")

      expect(CoPlan::UrlAlias.rewrite("hampton/cart-roadmap")).to eq("hampton/basket-roadmap")
    end

    it "does not record aliases for drafts nobody has linked yet" do
      plan = create(:plan, :draft, created_by_user: author, title: "Cart Roadmap")

      plan.update!(title: "Basket Roadmap")

      expect(CoPlan::UrlAlias.rewrite("hampton/cart-roadmap")).to be_nil
    end

    it "records the old URL when a published plan moves" do
      folder = create(:folder, name: "LiveOrder", created_by_user: author)
      plan = create(:plan, :published, created_by_user: author, title: "Basket Roadmap")

      place(plan, folder)

      expect(CoPlan::UrlAlias.rewrite("hampton/basket-roadmap"))
        .to eq("hampton/liveorder/basket-roadmap")
    end
  end
end
