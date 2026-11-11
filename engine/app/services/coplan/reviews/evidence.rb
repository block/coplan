module CoPlan
  module Reviews
    # Body/review writers serialize on this row too. This read deliberately
    # creates no PlanRead, agent session, or notification acknowledgement.
    class Evidence
      SCOPE = {
        kind: "markdown_source", includes: [ "content_markdown" ],
        excludes: %w[tags attachments linked_resources embedded_resources child_plans rendered_output],
        meaning: "Approval covers the Markdown source bytes, including the document title heading. Linked or embedded content is not captured or approved. Grants no execution authority or permissions."
      }.freeze

      def self.call(plan:)
        new(plan:).call
      end

      def initialize(plan:)
        @plan = plan
      end

      def call
        plan = @plan
        plan.with_lock do
          version = plan.current_plan_version
          requests = plan.review_requests.includes(:reviewer, :current_response, :review_responses).order(:id).to_a
          # Receipts need historical identity and hashes, not entire source
          # bodies. Keep only the current source read inside this evidence lock.
          ActiveRecord::Associations::Preloader.new(records: requests.flat_map(&:review_responses),
            associations: :plan_version, scope: PlanVersion.select(:id, :revision, :content_sha256)).call
          {
            schema_version: 1, plan_id: plan.id, review_sequence: plan.review_sequence,
            reset_reviews_on_change: plan.reset_reviews_on_change,
            approval_scope: SCOPE,
            version: { id: version.id, revision: version.revision,
                       content_sha256: version.content_sha256, content_markdown: version.verified_content! },
            review_requests: requests.map { |request| Serialize.call(request) }
          }
        end
      end
    end
  end
end
