module CoPlan
  module Plans
    class Create
      def self.call(title:, content:, user:, plan_type_id: nil)
        new(title:, content:, user:, plan_type_id:).call
      end

      def initialize(title:, content:, user:, plan_type_id: nil)
        @title = title
        @content = content
        @user = user
        @plan_type_id = plan_type_id
      end

      def call
        ActiveRecord::Base.transaction do
          plan = Plan.create!(title: @title, created_by_user: @user, plan_type_id: @plan_type_id)
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
      end
    end
  end
end
