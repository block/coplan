require "rails_helper"

# A URL segment inside a library belongs to one thing. Nothing in the
# database can say so — the contest runs across coplan_folders and
# coplan_plans, and a plan's own scope is split between coplan_plans (the
# slug) and coplan_plan_placements (the level) — so the write path decides
# it, and Library#lock_namespace! is what makes that decision hold.
RSpec.describe "Claiming a URL segment" do
  let(:author) { create(:coplan_user, username: "hampton") }
  let(:library) { author.library }

  # The FOR UPDATE the lock issues, as seen on the wire.
  def namespace_locks_during
    locks = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      locks += 1 if sql.include?("coplan_libraries") && sql.match?(/FOR UPDATE\z/i)
    end
    yield
    locks
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "takes the lock when asked inside a transaction" do
    expect { CoPlan::Library.transaction { library.lock_namespace! } }
      .not_to raise_error
  end

  # The sibling reads answer to two databases, and the suite normally only
  # runs one of them. PostgreSQL rejects FOR UPDATE on the nullable side of
  # an outer join outright — "cannot be applied", not a slow path — so a
  # left join here is a hard error on a host we support, discovered in CI
  # long after it reads fine locally on MySQL.
  #
  # The other half of the shape rule — coplan_plans stays in the outer
  # query, never behind a subquery the snapshot can filter — is what the
  # two-writer examples below actually prove, so it isn't restated here.
  it "reads siblings in a shape PostgreSQL will also lock" do
    folder = create(:folder, name: "LiveOrder", created_by_user: author)
    plan = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")

    [ nil, folder ].each do |level|
      sql = CoPlan::Plans::AssignSlug.new(plan: plan, folder: level).send(:siblings).lock.to_sql

      expect(sql).to match(/FOR UPDATE/i)
      expect(sql).not_to match(/LEFT OUTER JOIN/i), "FOR UPDATE over an outer join is a PostgreSQL error"
    end
  end

  describe "the writes that claim one" do
    it "locks when a plan takes its first segment" do
      taken = namespace_locks_during do
        create(:plan, :published, created_by_user: author, title: "Cart Roadmap")
      end

      expect(taken).to be >= 1
    end

    it "locks when a retitle moves a plan to a new segment" do
      plan = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")

      taken = namespace_locks_during { plan.update!(title: "Basket Roadmap") }

      expect(taken).to be >= 1
    end

    it "locks when a move re-derives the slug at a new level" do
      folder = create(:folder, name: "LiveOrder", created_by_user: author)
      plan = create(:plan, :published, created_by_user: author, title: "Cart Roadmap")

      taken = namespace_locks_during do
        CoPlan::Plans::Place.call(plan: plan, folder: folder, actor: author)
      end

      expect(taken).to be >= 1
    end

    # The folder's half of the same contest: it wins the segment, so the
    # sweep that pushes the shadowed plan aside has to run with nobody else
    # claiming here.
    it "locks when a folder is renamed onto a segment" do
      folder = create(:folder, name: "LiveOrder", created_by_user: author)

      taken = namespace_locks_during { folder.update!(name: "Orders") }

      expect(taken).to be >= 1
    end

    it "does not lock for an edit that claims nothing" do
      folder = create(:folder, name: "LiveOrder", created_by_user: author)

      taken = namespace_locks_during { folder.update!(description: "Cart and checkout.") }

      expect(taken).to eq(0)
    end
  end

  # The thing the lock is actually for. Two writers, two connections, one
  # library — the loser must wait, notice the segment is taken, and land on
  # its own address rather than a second copy of someone else's.
  describe "two writers at once", :aggregate_failures do
    # Real concurrency needs real connections, and a connection can't see
    # another's uncommitted rows.
    self.use_transactional_tests = false

    after { truncate_plan_tables }

    let!(:author) { create(:coplan_user, username: "hampton") }
    # Committed up front: two threads both reaching for the default type
    # would race on creating it, which is not what this example is about.
    let!(:plan_type) { CoPlan::PlanType.general }

    # A lock taken outside a transaction is released by the next statement,
    # so it would read as protection while providing none. Louder is safer —
    # and this group is the only one not already wrapped in a transaction by
    # the test harness, which is why the example lives here.
    it "refuses to pretend outside a transaction" do
      expect { author.library.lock_namespace! }
        .to raise_error(/must run inside a transaction/)
    end

    def in_parallel(count, &block)
      threads = count.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection { block.call(index) }
        end
      end
      # Bounded: a lock bug should fail the example, never hang the suite.
      threads.each { |thread| expect(thread.join(20)).to be_present }
      threads.map(&:value)
    end

    it "gives two same-titled plans two addresses" do
      plans = in_parallel(2) do |index|
        CoPlan::Plans::Create.call(
          title: "Cart Roadmap", content: "Draft #{index}.", user: author,
          plan_type_id: plan_type.id
        )
      end

      expect(plans.map(&:slug)).to eq([ "cart-roadmap", "cart-roadmap" ])
      # One of them moved out of the way, and it's the suffix that says so.
      expect(plans.map(&:slug_suffix).compact.size).to eq(1)
      expect(plans.map(&:url_path).uniq.size).to eq(2)
    end

    # Every address has to resolve back to the plan that owns it — two rows
    # agreeing on a path is exactly the failure the lock prevents, and
    # `uniq.size` alone wouldn't catch a path that resolves to neither.
    it "leaves both plans reachable" do
      plans = in_parallel(2) do |index|
        CoPlan::Plans::Create.call(
          title: "Cart Roadmap", content: "Draft #{index}.", user: author,
          plan_type_id: plan_type.id
        )
      end

      plans.each do |plan|
        handle, _, rest = plan.url_path.partition("/")
        result = CoPlan::Urls::Resolve.call(handle: handle, slug_path: rest)
        expect(result.plan&.id).to eq(plan.id), "#{plan.url_path} did not resolve to its own plan"
      end
    end
  end
end
