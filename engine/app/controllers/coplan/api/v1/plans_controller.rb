module CoPlan
  module Api
    module V1
      class PlansController < BaseController
        before_action :set_plan, only: [:show, :update, :versions, :comments, :snapshot]
        before_action :authorize_plan_access!, only: [:show, :update, :versions, :comments, :snapshot]

        def index
          plans = Plan
            .includes(:plan_type, :created_by_user)
            .where.not(status: "brainstorm")
            .or(Plan.where(created_by_user: current_user))
            .order(updated_at: :desc)
          plans = plans.where(status: params[:status]) if params[:status].present?
          render json: plans.map { |p| plan_json(p) }
        end

        def show
          render json: plan_json(@plan).merge(
            current_content: @plan.current_content,
            current_revision: @plan.current_revision,
            references: @plan.references.map { |r| reference_json(r) }
          )
        end

        def create
          if params[:plan_type].present?
            plan_type = PlanType.find_by(name: params[:plan_type])
            unless plan_type
              available = PlanType.order(:name).pluck(:name)
              message = "Unknown plan_type \"#{params[:plan_type]}\"."
              message += " Available types: #{available.map { |n| "\"#{n}\"" }.join(", ")}." if available.any?
              return render json: { error: message }, status: :unprocessable_content
            end
          end

          plan = nil
          ActiveRecord::Base.transaction do
            plan = Plans::Create.call(
              title: params[:title],
              content: params[:content] || "",
              user: current_user,
              plan_type_id: plan_type&.id
            )

            if params[:references].is_a?(Array)
              params[:references].each do |ref_params|
                next unless ref_params[:url].present?
                ref_type = ref_params[:reference_type].presence || Reference.classify_url(ref_params[:url])
                ref = plan.references.find_or_initialize_by(url: ref_params[:url])
                ref.assign_attributes(key: ref_params[:key], title: ref_params[:title], reference_type: ref_type, source: "explicit")
                ref.save!
              end
            end
          end

          render json: plan_json(plan).merge(
            current_content: plan.current_content,
            current_revision: plan.current_revision
          ), status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_content
        end

        def update
          policy = PlanPolicy.new(current_user, @plan)
          unless policy.update?
            return render json: { error: "Not authorized" }, status: :forbidden
          end

          permitted = {}
          permitted[:title] = params[:title] if params.key?(:title)
          permitted[:status] = params[:status] if params.key?(:status)

          @plan.tag_names = params[:tags] if params.key?(:tags)
          @plan.update!(permitted)

          if @plan.saved_changes?
            Broadcaster.replace_to(@plan, target: "plan-header", partial: "coplan/plans/header", locals: { plan: @plan })
          end

          if permitted.key?(:status) && @plan.saved_change_to_status?
            Plans::TriggerAutomatedReviews.call(plan: @plan, new_status: permitted[:status], triggered_by: current_user)
          end

          if params[:references].is_a?(Array)
            params[:references].each do |ref_params|
              next unless ref_params[:url].present?
              ref_type = ref_params[:reference_type].presence || Reference.classify_url(ref_params[:url])
              ref = @plan.references.find_or_initialize_by(url: ref_params[:url])
              ref.assign_attributes(key: ref_params[:key], title: ref_params[:title], reference_type: ref_type, source: "explicit")
              ref.save!
            end
          end

          render json: plan_json(@plan).merge(
            current_content: @plan.current_content,
            current_revision: @plan.current_revision
          )
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join(", ") }, status: :unprocessable_content
        end

        def versions
          versions = @plan.plan_versions.order(revision: :desc)
          render json: versions.map { |v| version_json(v) }
        end

        def comments
          threads = @plan.comment_threads.includes(:comments, :created_by_user).order(created_at: :desc)
          render json: threads.map { |t| thread_json(t) }
        end

        def snapshot
          threads = @plan.comment_threads.includes(:comments, :created_by_user).order(created_at: :desc)
          references = @plan.references.order(created_at: :desc)
          collaborators = @plan.plan_collaborators.includes(:user)

          render json: plan_json(@plan).merge(
            current_content: @plan.current_content,
            current_revision: @plan.current_revision,
            comment_threads: snapshot_threads_json(threads),
            references: references.map { |r| reference_json(r) },
            collaborators: collaborators.map { |c| collaborator_json(c) }
          )
        end

        private

        def plan_json(plan)
          {
            id: plan.id,
            title: plan.title,
            status: plan.status,
            current_revision: plan.current_revision,
            tags: plan.tag_names,
            plan_type_id: plan.plan_type_id,
            plan_type_name: plan.plan_type&.name,
            created_by: plan.created_by_user&.name,
            created_by_user: user_json(plan.created_by_user),
            created_at: plan.created_at,
            updated_at: plan.updated_at
          }
        end

        def version_json(version)
          {
            id: version.id,
            revision: version.revision,
            content_sha256: version.content_sha256,
            actor_type: version.actor_type,
            change_summary: version.change_summary,
            created_at: version.created_at
          }
        end

        def reference_json(ref)
          {
            id: ref.id,
            key: ref.key,
            url: ref.url,
            title: ref.title,
            reference_type: ref.reference_type,
            source: ref.source,
            target_plan_id: ref.target_plan_id
          }
        end

        def collaborator_json(collaborator)
          {
            id: collaborator.id,
            user: user_json(collaborator.user),
            role: collaborator.role
          }
        end

        def snapshot_threads_json(threads)
          content = @plan.current_content
          stripped_data = if content.present?
            stripped, pos_map = CoPlan::CommentThread.strip_markdown(content)
            { stripped: stripped, pos_map: pos_map }
          end

          threads.map do |t|
            occurrence = compute_anchor_occurrence(t, content, stripped_data)
            thread_json(t).merge(anchor_occurrence: occurrence)
          end
        end

        def compute_anchor_occurrence(thread, content, stripped_data)
          return nil unless thread.anchored? && content.present? && thread.anchor_start.present?
          return nil unless stripped_data

          stripped = stripped_data[:stripped]
          pos_map = stripped_data[:pos_map]
          stripped_start = pos_map.index { |raw_idx| raw_idx >= thread.anchor_start }
          return nil if stripped_start.nil?

          normalized_anchor = thread.anchor_text.gsub("\t", " ")
          ranges = []
          start_pos = 0
          while (idx = stripped.index(normalized_anchor, start_pos))
            ranges << idx
            start_pos = idx + normalized_anchor.length
          end
          ranges.index { |s| s >= stripped_start } || 0
        end

        def thread_json(thread)
          {
            id: thread.id,
            status: thread.status,
            anchor_text: thread.anchor_text,
            anchor_context: thread.anchor_context_with_highlight,
            anchor_valid: thread.anchor_valid?,
            start_line: thread.start_line,
            end_line: thread.end_line,
            out_of_date: thread.out_of_date,
            created_by: thread.created_by_user&.name,
            created_by_user: user_json(thread.created_by_user),
            created_at: thread.created_at,
            comments: thread.comments.sort_by(&:created_at).map { |c|
              {
                id: c.id,
                author_type: c.author_type,
                author_id: c.author_id,
                agent_name: c.agent_name,
                body_markdown: c.body_markdown,
                created_at: c.created_at
              }
            }
          }
        end

        def user_json(user)
          return nil unless user
          {
            id: user.id,
            name: user.name
          }
        end
      end
    end
  end
end
