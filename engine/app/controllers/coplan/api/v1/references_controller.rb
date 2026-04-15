module CoPlan
  module Api
    module V1
      class ReferencesController < BaseController
        before_action :set_plan, only: [:index, :create, :destroy]
        before_action :authorize_plan_access!, only: [:index, :create, :destroy]
        before_action :authorize_plan_write!, only: [:create, :destroy]

        def index
          references = @plan.references.order(created_at: :desc)
          references = references.where(reference_type: params[:type]) if params[:type].present?
          render json: references.map { |r| reference_json(r) }
        end

        def create
          ref_type = params[:reference_type].presence || Reference.classify_url(params[:url])
          target_plan_id = nil
          if ref_type == "plan"
            candidate_id = Reference.extract_target_plan_id(params[:url])
            target_plan_id = candidate_id if candidate_id && candidate_id != @plan.id && Plan.exists?(candidate_id)
          end

          ref = @plan.references.find_or_initialize_by(url: params[:url])
          ref.assign_attributes(
            key: params[:key],
            title: params[:title],
            reference_type: ref_type,
            source: "explicit",
            target_plan_id: target_plan_id || params[:target_plan_id]
          )
          ref.save!

          render json: reference_json(ref), status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_content
        end

        def destroy
          ref = @plan.references.find_by(id: params[:id])
          unless ref
            render json: { error: "Reference not found" }, status: :not_found
            return
          end

          ref.destroy!
          head :no_content
        end

        def search
          url = params[:url]
          unless url.present?
            render json: { error: "url parameter is required" }, status: :unprocessable_content
            return
          end

          visible_plans = Plan.where.not(status: "brainstorm")
            .or(Plan.where(created_by_user: current_user))

          references = Reference.where(url: url, plan_id: visible_plans.select(:id))
            .includes(:plan)
            .order(created_at: :desc)

          render json: references.map { |r|
            reference_json(r).merge(
              plan_id: r.plan_id,
              plan_title: r.plan.title,
              plan_status: r.plan.status
            )
          }
        end

        private

        def authorize_plan_write!
          return unless @plan
          policy = CoPlan::PlanPolicy.new(current_user, @plan)
          unless policy.update?
            render json: { error: "Not authorized" }, status: :forbidden
          end
        end

        def reference_json(ref)
          {
            id: ref.id,
            key: ref.key,
            url: ref.url,
            title: ref.title,
            reference_type: ref.reference_type,
            source: ref.source,
            target_plan_id: ref.target_plan_id,
            created_at: ref.created_at,
            updated_at: ref.updated_at
          }
        end
      end
    end
  end
end
