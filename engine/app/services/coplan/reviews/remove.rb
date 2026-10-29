module CoPlan
  module Reviews
    # A later assignment gets a fresh ID, so old response URLs stay invalid.
    class Remove
      def self.call(plan:, request_id:)
        request = plan.with_lock do
          request = plan.review_requests.find_by(id: request_id)
          request&.destroy!
          request
        end
        Changed.call(request: request, event_type: "review.requested",
          payload: { "action" => "removed", "removed" => true }) if request
        request
      end
    end
  end
end
