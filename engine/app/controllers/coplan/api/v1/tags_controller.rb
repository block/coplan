module CoPlan
  module Api
    module V1
      class TagsController < BaseController
        def index
          visible_plans = Plan.where.not(status: "brainstorm")
            .or(Plan.where(created_by_user: current_user))

          tags = Tag
            .joins(:plan_tags)
            .where(plan_tags: { plan_id: visible_plans.select(:id) })
            .select("coplan_tags.*, COUNT(plan_tags.plan_id) AS visible_plans_count")
            .group("coplan_tags.id")
            .order("visible_plans_count DESC, coplan_tags.name ASC")

          render json: tags.map { |t|
            {
              id: t.id,
              name: t.name,
              plans_count: t.visible_plans_count,
              created_at: t.created_at,
              updated_at: t.updated_at
            }
          }
        end
      end
    end
  end
end
