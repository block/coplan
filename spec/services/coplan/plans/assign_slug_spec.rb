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
