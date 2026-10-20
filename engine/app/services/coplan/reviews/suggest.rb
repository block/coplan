module CoPlan
  module Reviews
    # Asks the host who should review a plan. Suggestions are advice for the
    # author: nothing is requested until someone acts on one.
    class Suggest
      Suggestion = Data.define(:user, :reason, :requirement) do
        def as_json(*)
          { reviewer: { id: user.id, name: user.name, username: user.username, avatar_url: user.avatar_url, team: user.team },
            reason: reason, requirement: requirement }
        end
      end

      def self.call(plan:)
        new(plan:).call
      end

      def initialize(plan:)
        @plan = plan
      end

      def call
        hook = CoPlan.configuration.suggest_reviewers
        return [] unless hook

        taken = @plan.review_requests.active.pluck(:reviewer_id) << @plan.created_by_user_id
        Array(hook.call(@plan)).filter_map { |entry| suggestion(entry) }
          .reject { |suggestion| taken.include?(suggestion.user.id) }
          .uniq { |suggestion| suggestion.user.id }
      rescue StandardError => e
        CoPlan.configuration.error_reporter&.call(e, { source: "suggest_reviewers", plan_id: @plan.id })
        []
      end

      private

      def suggestion(entry)
        entry = entry.is_a?(User) ? { user: entry } : entry.to_h.symbolize_keys
        user = entry[:user]
        return unless user.is_a?(User) && user.persisted?

        requirement = entry[:requirement].to_s
        Suggestion.new(user: user, reason: entry[:reason].presence,
          requirement: ReviewRequest::REQUIREMENTS.include?(requirement) ? requirement : "required")
      end
    end
  end
end
