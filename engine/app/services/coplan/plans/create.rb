module CoPlan
  module Plans
    class Create
      # Plans are shared by default: they're created published unless the
      # caller explicitly asks for a private draft.
      def self.call(title:, content:, user:, plan_type_id: nil, visibility: "published")
        new(title:, content:, user:, plan_type_id:, visibility:).call
      end

      def initialize(title:, content:, user:, plan_type_id: nil, visibility: "published")
        @title = title
        @content = content
        @user = user
        @plan_type_id = plan_type_id
        @visibility = visibility
      end

      def call
        plan = ActiveRecord::Base.transaction do
          plan = Plan.create!(title: @title, created_by_user: @user, plan_type_id: @plan_type_id, visibility: @visibility)
          version = PlanVersion.create!(
            plan: plan,
            revision: 1,
            content_markdown: @content,
            actor_type: "human",
            actor_id: @user.id
          )
          plan.update!(current_plan_version: version, current_revision: 1)
          plan
        end

        CoPlan::Analytics.track(
          "plan_created",
          user: @user,
          plan_id: plan.id,
          plan_type_id: plan.plan_type_id,
          visibility: plan.visibility,
          content_length: @content.to_s.length
        )

        plan
      end
    end
  end
end
