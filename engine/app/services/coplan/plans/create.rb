module CoPlan
  module Plans
    class Create
      # Plans are shared by default: they're created published unless the
      # caller explicitly asks for an unlisted draft.
      def self.call(
        title:, content:, user:, plan_type_id: nil, visibility: "published",
        actor_type: "human", actor_id: nil, agent_name: nil, api_token_id: nil
      )
        new(title:, content:, user:, plan_type_id:, visibility:, actor_type:, actor_id:, agent_name:, api_token_id:).call
      end

      def initialize(
        title:, content:, user:, plan_type_id: nil, visibility: "published",
        actor_type: "human", actor_id: nil, agent_name: nil, api_token_id: nil
      )
        @title = title
        @content = content
        @user = user
        @plan_type_id = plan_type_id
        @visibility = visibility
        @actor_type = actor_type
        @actor_id = actor_id || user.id
        @agent_name = agent_name
        @api_token_id = api_token_id
      end

      def call
        plan = ActiveRecord::Base.transaction do
          plan = Plan.create!(title: @title, created_by_user: @user, plan_type_id: @plan_type_id, visibility: @visibility)
          version = PlanVersion.create!(
            plan: plan,
            revision: 1,
            # Normalize line endings on the way in (ReplaceContent does the
            # same) — otherwise a CRLF-created document diffs against its
            # LF-edited successor on every line.
            content_markdown: @content.to_s.delete("\r"),
            actor_type: @actor_type,
            actor_id: @actor_id,
            agent_name: @agent_name,
            api_token_id: @api_token_id
          )
          plan.update!(current_plan_version: version, current_revision: 1)
          plan
        end

        # Deferred: callers may wrap creation in a larger transaction (the
        # API's create-and-file does), and a rollback there must not leave
        # behind an analytics event for a plan that never existed. Outside
        # any transaction this runs immediately.
        ActiveRecord.after_all_transactions_commit do
          CoPlan::Analytics.track(
            "plan_created",
            user: @user,
            plan_id: plan.id,
            plan_type_id: plan.plan_type_id,
            visibility: plan.visibility,
            content_length: @content.to_s.length
          )
        end

        plan
      end
    end
  end
end
