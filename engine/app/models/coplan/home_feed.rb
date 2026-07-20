module CoPlan
  # The Home activity feed: what happened to publicly listed plans lately,
  # rolled up per plan per day. Agent editing loops push a plan through
  # dozens of revisions in hours — per-edit entries would drown the feed,
  # but "Payments Plan · 29 edits · 4 comments · today" reads in a glance.
  #
  # Only publicly listed work appears (Plan.publicly_listed): drafts and
  # archived plans never show up on Home, whoever is looking.
  class HomeFeed
    WINDOW = 14.days
    MAX_ITEMS = 40

    Item = Struct.new(:plan, :date, :published, :edits, :comments, :last_activity_at, keyword_init: true) do
      # One human phrase for the day's activity, e.g. "new · 3 edits".
      # "new", not "published" — published is the unmarked normal state;
      # the interesting fact is that the plan just appeared.
      def summary_parts
        parts = []
        parts << "new" if published
        parts << "#{edits} #{edits == 1 ? "edit" : "edits"}" if edits.positive?
        parts << "#{comments} #{comments == 1 ? "comment" : "comments"}" if comments.positive?
        parts
      end
    end

    # Returns Items sorted by most recent activity, newest first.
    def self.build(now: Time.current)
      since = now - WINDOW
      listed = Plan.publicly_listed.select(:id)

      rollups = Hash.new do |h, k|
        h[k] = { published: false, edits: 0, comments: 0, last_at: nil }
      end
      note = lambda do |plan_id, at|
        rollup = rollups[[ plan_id, at.to_date ]]
        rollup[:last_at] = at if rollup[:last_at].nil? || at > rollup[:last_at]
        rollup
      end

      # Revision 1 is the plan coming into existence — for born-published
      # plans that IS the publish moment, so it reads as "published". Plans
      # with a "published" event got listed later: their publish moment comes
      # from the event query below, and their revision 1 predates being
      # visible at all, so it isn't feed activity.
      published_by_event = PlanEvent.where(plan_id: listed, event_type: "published")
        .distinct.pluck(:plan_id).to_set
      PlanVersion.where(plan_id: listed).where(created_at: since..)
        .pluck(:plan_id, :created_at, :revision)
        .each do |plan_id, at, revision|
          next if revision == 1 && published_by_event.include?(plan_id)
          rollup = note.call(plan_id, at)
          revision == 1 ? rollup[:published] = true : rollup[:edits] += 1
        end

      PlanEvent.where(plan_id: listed, event_type: "published").where(created_at: since..)
        .pluck(:plan_id, :created_at)
        .each { |plan_id, at| note.call(plan_id, at)[:published] = true }

      Comment.kept.joins(:comment_thread)
        .where(coplan_comment_threads: { plan_id: listed })
        .where(coplan_comments: { created_at: since.. })
        .pluck("coplan_comment_threads.plan_id", "coplan_comments.created_at")
        .each { |plan_id, at| note.call(plan_id, at)[:comments] += 1 }

      top = rollups.sort_by { |_key, rollup| -rollup[:last_at].to_i }.first(MAX_ITEMS)
      plans = Plan.where(id: top.map { |(plan_id, _date), _| plan_id }.uniq)
        .includes(:created_by_user, :plan_type, :tags)
        .index_by(&:id)

      top.filter_map do |(plan_id, date), rollup|
        plan = plans[plan_id]
        next unless plan

        Item.new(
          plan: plan,
          date: date,
          published: rollup[:published],
          edits: rollup[:edits],
          comments: rollup[:comments],
          last_activity_at: rollup[:last_at]
        )
      end
    end
  end
end
