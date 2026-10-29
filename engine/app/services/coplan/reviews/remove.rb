module CoPlan
  module Reviews
    # Removing a reviewer ends the request's identity. A later assignment gets
    # a new ID, so delayed responses to the old request cannot complete it.
    # API withdrawal is separate and continues to preserve review history.
    class Remove
      def self.call(plan:, request_id:)
        removed_events = []
        request = plan.with_lock do
          request = plan.review_requests.find_by(id: request_id)
          next unless request

          events = plan.plan_events.where(event_type: %w[review_requested review_withdrawn], after_value: request.id)
          removed_events = events.to_a
          events.delete_all
          event_ids = AgentEvent.where(plan: plan, event_type: %w[review.requested review.responded]).pluck(:id, :payload).filter_map do |id, payload|
            id if payload.to_h["review_request_id"] == request.id
          end
          AgentEvent.where(id: event_ids).delete_all
          request.destroy!
          request
        end
        if request
          removed_events.each { |event| Broadcaster.remove_to(plan, target: ActionView::RecordIdentifier.dom_id(event)) }
          count = plan.plan_versions.count + plan.plan_events.count
          Broadcaster.replace_to(plan, target: "history-count",
            html: ApplicationController.helpers.content_tag(:span, ApplicationController.helpers.pluralize(count, "entry"), class: "section-count", id: "history-count"))
          Changed.call(request: request, event_type: "review.requested", payload: { "action" => "removed", "removed" => true })
        end
        request
      end
    end
  end
end
