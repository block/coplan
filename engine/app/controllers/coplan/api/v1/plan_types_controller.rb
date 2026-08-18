module CoPlan
  module Api
    module V1
      # Read-only catalog of plan types. Agents fetch this before creating a
      # plan to pick the most specific type and read its template — the
      # template ships here in full because the whole point is that the
      # agent structures its draft against it before writing any content.
      class PlanTypesController < BaseController
        def index
          types = PlanType.order(:name)
          render json: types.map { |pt|
            {
              id: pt.id,
              name: pt.name,
              description: pt.description,
              default_tags: pt.default_tags,
              template_content: pt.template_content
            }
          }
        end
      end
    end
  end
end
