module CoPlan
  module Reviews
    # Body/review writers serialize on this row too. This read deliberately
    # creates no PlanRead, agent session, or notification acknowledgement.
    class Evidence
      SCOPE = {
        kind: "markdown_source", includes: [ "content_markdown" ],
        excludes: %w[title tags attachments linked_resources embedded_resources child_plans rendered_output],
        meaning: "Approval covers the Markdown source bytes only. Linked or embedded content is not captured or approved. Grants no execution authority or permissions."
      }.freeze

      def self.call(plan:)
        plan.with_lock do
          version = plan.current_plan_version
          {
            schema_version: 1, plan_id: plan.id, review_sequence: plan.review_sequence,
            reset_reviews_on_change: plan.reset_reviews_on_change,
            approval_scope: SCOPE,
            version: { id: version.id, revision: version.revision,
                       content_sha256: version.content_sha256, content_markdown: version.verified_content! },
            review_requests: plan.review_requests.includes(:reviewer, :current_response,
              review_responses: :plan_version).order(:id).map { |request| Serialize.call(request) }
          }
        end
      end
    end
  end
end
