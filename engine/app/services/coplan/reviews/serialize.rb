module CoPlan
  module Reviews
    class Serialize
      def self.call(request)
        new(request).call
      end

      def initialize(request)
        @request = request
      end

      def call
        request = @request
        {
          id: request.id, reviewer: { id: request.reviewer_id, name: request.reviewer.name },
          requirement: request.requirement, status: request.status, review_status: request.review_status, effective_status: request.effective_status,
          requested_at: request.requested_at, generation: request.generation, reset_reason: request.reset_reason,
          current_response_id: request.current_response_id,
          recorded_response_id: request.recorded_response&.id,
          effective_response_id: request.effective_response&.id,
          effective_human_decision: request.effective_human_decision,
          latest_human_response_id: request.review_responses.find { |response|
            response.actor_type == "human" && response.decision_sequence && response.plan_version_id == request.plan.current_plan_version_id
          }&.id,
          responses: request.review_responses.map do |response|
            { id: response.id, decision: response.decision, revision: response.plan_version.revision,
              plan_version_id: response.plan_version_id, content_sha256: response.plan_version.content_sha256,
              generation: response.request_generation, decision_sequence: response.decision_sequence,
              user_id: response.user_id, api_token_id: response.api_token_id, actor_type: response.actor_type, agent_name: response.agent_name,
              note: response.note, comment_thread_id: response.comment_thread_id, created_at: response.created_at }
          end
        }
      end
    end
  end
end
