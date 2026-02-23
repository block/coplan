module Plans
  class TriggerAutomatedReviews
    def self.call(plan:, new_status:, triggered_by:)
      new(plan:, new_status:, triggered_by:).call
    end

    def initialize(plan:, new_status:, triggered_by:)
      @plan = plan
      @new_status = new_status
      @triggered_by = triggered_by
    end

    def call
      reviewers = @plan.organization.automated_plan_reviewers.enabled
      reviewers.each do |reviewer|
        next unless reviewer.triggers_on_status?(@new_status)

        AutomatedReviewJob.perform_later(
          plan_id: @plan.id,
          reviewer_id: reviewer.id,
          triggered_by: @triggered_by
        )
      end
    end
  end
end
