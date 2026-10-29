module CoPlan
  module Plans
    # All current-version writers call this inside their plan-row transaction.
    # CommitSession still locks its session before the plan.
    class AdvanceVersion
      def self.call(plan:, version:)
        raise ArgumentError, "Version advancement requires the writer’s plan transaction" unless plan.class.connection.transaction_open?
        raise ArgumentError, "Version must belong to the plan and advance its revision" unless version.plan_id == plan.id && version.revision > plan.current_revision

        plan.update!(current_plan_version: version, current_revision: version.revision,
          review_sequence: plan.review_sequence + 1)
        requests = plan.reset_reviews_on_change? ? plan.review_requests.active.to_a : []
        requests.each do |request|
          request.update!(status: "pending", generation: request.generation + 1,
            current_response: nil, reset_reason: "content_changed")
        end
        # No new review notifications for each edit, and no reset broadcast
        # for a transaction that rolls back.
        ActiveRecord.after_all_transactions_commit do
          requests.each do |request|
            begin
              Reviews::Changed.call(request: request, event_type: "review.requested",
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
