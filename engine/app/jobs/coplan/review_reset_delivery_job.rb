module CoPlan
  # A failed reset delivery is an invalidation and may be delivered again.
  # Skip it when the request has since been removed, decided or reopened.
  class ReviewResetDeliveryJob < ApplicationJob
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(request_id:, generation:, revision:, actor_token_id: nil)
      request = ReviewRequest.find_by(id: request_id)
      return unless request&.pending? && request.generation == generation

      Reviews::Changed.call(request: request, event_type: "review.requested",
        actor_token_id: actor_token_id, broadcast_controls: false,
        payload: { "action" => "content_changed", "revision" => revision, "generation" => generation })
    end
  end
end
