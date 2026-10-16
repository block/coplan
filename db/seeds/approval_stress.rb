module CoPlan
  # Opt-in local data for trying the approval table, timeline and discussions
  # at scale. Existing decisions and local edits survive repeated runs.
  module ApprovalStressSeed
    module_function

    PEOPLE = [
      "Maya Chen", "Oliver Brooks", "Priya Shah", "Mateo Alvarez", "Aiko Tanaka", "Noura Haddad", "Sam Rivera", "Alex Morgan",
      "Jordan Lee", "Fatima Hassan", "Luca Rossi", "Grace Kim", "Diego Torres", "Amara Okafor", "Noah Patel", "Sofia Garcia",
      "Ethan Clark", "Isabella Nguyen", "Arjun Mehta", "Chloe Martin", "Leo Fischer", "Zara Ahmed", "Daniel Park", "Elena Petrova",
      "Marcus Williams", "Yuki Sato", "Anika Das", "Theo Wilson", "Camila Costa", "Ravi Kumar", "Freya Jensen", "Omar Ali"
    ].freeze
    FEEDBACK = [
      "Please describe the rollback trigger and who owns the decision during the first rollout window.",
      "The retry contract needs an explicit timeout. Can we show what the client sees after reconciliation times out?",
      "Add the verification query and expected result so on-call can confirm recovery without guessing.",
      "The contract looks good. The updated examples cover the idempotency boundary clearly.",
      "Can we spell out the migration steps for clients that still use the previous response shape?",
      "I reviewed the revised monitoring section and agree with the thresholds and escalation path.",
      "Please separate a confirmed rejection from an unknown outcome in the SDK examples.",
      "The new rollout guard addresses my earlier concern. The operational ownership is clear now."
    ].freeze

    def call(owner:)
      raise "Approval stress data is only for local development or tests" unless Rails.env.local?
      previous_adapter = ActiveJob::Base.queue_adapter
      # Historical fixture comments must not send integration notifications.
      ActiveJob::Base.queue_adapter = :test
      plan = owner.created_plans.find_by(slug: "approval-stress-test")
      unless plan
        plan = Plans::Create.call(title: "Release readiness — approval stress test", content: content(1), user: owner, visibility: "published")
        plan.update!(slug: "approval-stress-test")
      end
      versions = (1..8).map do |revision|
        plan.plan_versions.find_or_create_by!(revision: revision) do |version|
          version.content_markdown = content(revision)
          version.actor_type = "human"
          version.actor_id = owner.id
          version.created_at = 20.days.ago + revision.days
        end
      end
      # Leave a manually edited demo version untouched on later seed runs.
      plan.update!(current_plan_version: versions.last, current_revision: 8) if plan.current_revision < 8
      reviewers = PEOPLE.map.with_index do |name, index|
        User.find_or_create_by!(external_id: "approval-demo-#{index}@example.test") do |user|
          user.name = name
          user.email = "approval-demo-#{index}@example.test"
          user.username = "approval-demo-#{index}"
          user.team = %w[Platform Security SDK Reliability Product Infrastructure][index % 6]
        end
      end + [ owner ]
      reviewers.each_with_index do |reviewer, index|
        request = plan.review_requests.find_or_create_by!(reviewer: reviewer) do |entry|
          entry.requested_by_user = owner
          entry.requested_plan_version = versions.first
          entry.requirement = index < 24 || reviewer == owner ? "required" : "optional"
          entry.status = "pending"
          entry.requested_at = 19.days.ago + index.hours
        end
        next if request.review_responses.any?
        responded_versions = index < 22 ? versions.first(7) : []
        responded_versions += [ versions.last ] if index < 18
        responded_versions.each do |version|
          decision = (index + version.revision) % 5 == 0 ? "changes_requested" : "approved"
          note = FEEDBACK[(index + version.revision) % FEEDBACK.size]
          at = 20.days.ago + version.revision.days + index.hours
          thread = nil
          if decision == "changes_requested" || index % 3 == 0
            thread = plan.comment_threads.create!(plan_version: version, created_by_user: reviewer,
              status: version.revision < 6 ? "resolved" : "open", created_at: at)
            thread.comments.create!(author_type: "human", author_id: reviewer.id, body_markdown: note, created_at: at)
            if index % 4 == 0
              thread.comments.create!(author_type: "human", author_id: owner.id,
                body_markdown: "Updated the examples and verification steps. Could you take another look?", created_at: at + 2.hours)
            end
          end
          request.review_responses.create!(plan_version: version, user: reviewer, decision: decision,
            note: thread ? note : nil, comment_thread: thread, actor_type: "human", created_at: at)
        end
        request.update!(status: request.review_responses.first&.decision || "pending")
      end
      plan
    ensure
      ActiveJob::Base.queue_adapter = previous_adapter if previous_adapter
    end

    def content(revision)
      <<~MD
        # Release readiness

        Coordinate the OrderCart rollout across platform, SDK, security and reliability teams. This demonstration includes eight revisions and a deliberately busy review history.

        ## Shared contract

        Each operation carries one stable idempotency key. Clients reconcile an unknown outcome before submitting again. Revision #{revision} clarifies the recovery examples and ownership of the rollout gates.

        ## Verification

        Compare reconciliation success, retry counts and duplicate-operation rates against the baseline. Stop expansion if the recovery error budget is exhausted. On-call owns rollback; the release lead owns resuming rollout.

        ## Rollout

        Start with internal clients, then expand through 1%, 10%, 50% and 100% cohorts. Keep each cohort stable for one observation window. Every gate records the verification result and the person making the decision.
      MD
    end
  end
end
