module CoPlan
  module Plans
    # All current-version writers call this inside their plan-row transaction.
    # CommitSession still locks its session before the plan.
    class AdvanceVersion
      def self.call(plan:, version:)
        new(plan:, version:).call
      end

      def initialize(plan:, version:)
        @plan, @version = plan, version
      end

      def call
        plan, version = @plan, @version
        raise ArgumentError, "Version advancement requires the writer’s plan transaction" unless plan.class.connection.transaction_open?
        raise ArgumentError, "Version must belong to the plan and advance its revision" unless version.plan_id == plan.id && version.revision > plan.current_revision

        plan.update!(current_plan_version: version, current_revision: version.revision,
          review_sequence: plan.review_sequence + 1)
        requests = []
        if plan.reset_reviews_on_change?
          active_requests = plan.review_requests.active
          # The plan lock serializes every review writer. Only reset projection
          # fields change here; validating unchanged version associations would
          # load full historical Markdown once per reviewer inside that lock.
          active_requests.update_all(status: "pending", generation: Arel.sql("generation + 1"),
            current_response_id: nil, reset_reason: "content_changed", updated_at: Time.current)
          requests = active_requests.reload.to_a
        end
        # No new review notifications for each edit, and no reset broadcast
        # for a transaction that rolls back.
        ActiveRecord.after_all_transactions_commit do
          requests.each do |request|
            begin
              # Another writer can finish after commit releases the plan lock.
              # Match retry delivery: suppress obsolete or removed reset tasks.
              current_request = ReviewRequest.find_by(id: request.id)
              next unless current_request&.pending? && current_request.generation == request.generation

              Reviews::Changed.call(request: current_request, event_type: "review.requested",
                actor_token_id: version.api_token_id, broadcast_controls: false,
                payload: { "action" => "content_changed", "revision" => version.revision,
                           "generation" => request.generation })
            rescue StandardError => error
              Rails.error.report(error)
              begin
                ReviewResetDeliveryJob.perform_later(request_id: request.id, generation: request.generation,
                  revision: version.revision, actor_token_id: version.api_token_id)
              rescue StandardError => enqueue_error
                Rails.error.report(enqueue_error)
              end
            end
          end
          begin
            Broadcaster.custom_action_to(plan, action: "coplan-review-changed", target: "plan-review-controls", html: "")
          rescue StandardError => error
            Rails.error.report(error)
            begin
              ReviewResetDeliveryJob.perform_later(plan_id: plan.id)
            rescue StandardError => enqueue_error
              Rails.error.report(enqueue_error)
            end
          end
        end
        version
      end
    end
  end
end
