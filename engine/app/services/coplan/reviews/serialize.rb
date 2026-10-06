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
          requirement: request.requirement, status: request.status,
          requested_revision: request.requested_plan_version.revision, requested_at: request.requested_at,
          responses: request.review_responses.map do |response|
            { id: response.id, decision: response.decision, revision: response.plan_version.revision,
              user_id: response.user_id, actor_type: response.actor_type, agent_name: response.agent_name,
              note: response.note, comment_thread_id: response.comment_thread_id, created_at: response.created_at }
          end
        }
      end
    end
  end
end
