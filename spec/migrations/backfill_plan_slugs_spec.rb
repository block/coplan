require "rails_helper"
require CoPlan::Engine.root.join("db/migrate/20260823000000_backfill_plan_slugs.rb")

# A one-shot that hands real documents their permanent addresses. There is
# no second run to correct a mistake and no unique index to catch one, so
# the interesting cases get exercised before it meets production data.
RSpec.describe BackfillPlanSlugs do
  subject(:migration) { described_class.new }

  # The column this migration exists to fill is NOT NULL afterwards, which
  # is exactly the state a plan can't be put into from the model layer —
  # so the "before" state has to be built with the constraint lifted, the
  # way the database actually looked when the migration was written.
  # DDL commits implicitly on MySQL, so this group can't run in one.
  self.use_transactional_tests = false

  before do
    migration.verbose = false
    connection.change_column_null(:coplan_plans, :slug, true)
  end

  after do
    connection.change_column_null(:coplan_plans, :slug, false)
    truncate_plan_tables
  end

  let!(:author) { create(:coplan_user, username: "hampton") }
  let!(:plan_type) { CoPlan::PlanType.general }

  def connection
    ActiveRecord::Base.connection
  end

  # Straight to the columns: assigning through the model would just call
  # the app's own slug rules, which is the thing being stood in for.
  def unslug(plan)
    plan.update_columns(slug: nil, slug_suffix: nil)
    plan
  end

  def leaf(plan)
    plan.reload
    [ plan.slug, plan.slug_suffix ]
  end

  it "gives a plan with no slug the readable leaf of its title" do
    plan = unslug(create(:plan, :published, created_by_user: author, title: "Cart Roadmap"))

    migration.up

    expect(leaf(plan)).to eq([ "cart-roadmap", nil ])
  end

  it "strips what the path already says" do
    folder = create(:folder, name: "LiveOrder", created_by_user: author)
    plan = create(:plan, :published, created_by_user: author, title: "LiveOrder Cart Roadmap")
    CoPlan::Plans::Place.call(plan: plan, folder: folder, actor: author)
    unslug(plan)

    migration.up

    expect(leaf(plan)).to eq([ "cart-roadmap", nil ])
  end

  it "moves a backfilled plan aside rather than onto a slug already in use" do
    holder = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")
    holder.update_columns(slug: "cart-roadmap", slug_suffix: nil)
    late = unslug(create(:plan, :published, created_by_user: author, title: "Cart Roadmap"))

    migration.up

    expect(leaf(holder)).to eq([ "cart-roadmap", nil ])
    expect(leaf(late).first).to eq("cart-roadmap")
    expect(leaf(late).last).to be_present
  end

  # The suffix is derived from the plan id so that re-running produces the
  # same URLs — which also means it can't be re-rolled on a collision, so
  # the leaves already spoken for have to be known before the first guess.
  # A sibling holding that exact suffix is astronomically unlikely and
  # completely silent: two documents, one address, nothing to reject it.
  it "does not hand a backfilled plan a suffix a sibling already holds" do
    holder = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")
    holder.update_columns(slug: "cart-roadmap", slug_suffix: nil)
    late = unslug(create(:plan, :published, created_by_user: author, title: "Cart Roadmap"))

    # Whatever the migration would reach for first, someone already has.
    squatter = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")
    squatter.update_columns(
      slug: "cart-roadmap", slug_suffix: migration.send(:suffix_for, late.id, 0)
    )

    migration.up

    expect(leaf(late)).not_to eq(leaf(squatter))
    expect([ leaf(holder), leaf(late), leaf(squatter) ].uniq.size).to eq(3)
  end

  it "leaves a plan that already has a slug alone" do
    plan = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")
    plan.update_columns(slug: "an-older-name", slug_suffix: nil)

    migration.up

    expect(leaf(plan)).to eq([ "an-older-name", nil ])
  end

  it "makes a plan without a slug unrepresentable afterwards" do
    unslug(create(:plan, :published, created_by_user: author, title: "Cart Roadmap"))

    migration.up

    expect { CoPlan::Plan.last.update_columns(slug: nil) }
      .to raise_error(ActiveRecord::NotNullViolation)
  end
end
