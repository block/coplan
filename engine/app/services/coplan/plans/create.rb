module CoPlan
  module Plans
    class Create
      def self.call(title:, content:, user:)
        new(title:, content:, user:).call
      end

      def initialize(title:, content:, user:)
        @title = title
        @content = content
        @user = user
      end

      def call
        ActiveRecord::Base.transaction do
          plan = Plan.create!(title: @title, created_by_user: @user)
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
