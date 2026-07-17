module CoPlan
  module Api
    module V1
      class PlansController < BaseController
        before_action :set_plan, only: [ :show, :update, :versions, :comments, :snapshot ]
        before_action :authorize_plan_access!, only: [ :show, :update, :versions, :comments, :snapshot ]

        def index
          plans = Plan
            .includes(:plan_type, :created_by_user, folder: { parent: :parent })
            .visible_to(current_user)
            .order(updated_at: :desc)
          plans = apply_index_filters(plans)
          plans = plans.where(folder_id: params[:folder_id]) if params[:folder_id].present?
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

          # Plans are born published; `"visibility": "draft"` is the opt-in
          # for starting private.
          visibility = params[:visibility].presence || "published"
          unless Plan::VISIBILITIES.include?(visibility)
            return render json: { error: "visibility must be one of: #{Plan::VISIBILITIES.join(", ")}" }, status: :unprocessable_content
          end

          plan = nil
          ActiveRecord::Base.transaction do
            plan = Plans::Create.call(
              title: params[:title],
              content: params[:content] || "",
              user: current_user,
              plan_type_id: plan_type&.id,
              visibility: visibility
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
          visibility_updates = visibility_params_for_update
          return if performed? # visibility_params_for_update rendered an error
          permitted.merge!(visibility_updates)

          # Snapshot before-state so LogEvent can record meaningful diffs.
          old_title = @plan.title
          old_visibility = @plan.visibility
          old_archived = @plan.archived?
          old_tag_names = @plan.tag_names
          old_folder_path = @plan.folder&.path

          # Folder resolution (which may create folders via folder_path) and
          # the plan update are one transaction: a request combining
          # folder_path with an invalid attribute must not leave behind
          # orphaned shared folders for a move that never happened.
          ActiveRecord::Base.transaction do
            if params.key?(:folder_id) || params.key?(:folder_path)
              folder = resolve_folder_params
              return if performed? # resolve_folder_params rendered an error
              @plan.folder = folder
            end

            @plan.tag_names = params[:tags] if params.key?(:tags)
            @plan.update!(permitted)
          end

          if @plan.saved_changes?
            Broadcaster.replace_to(@plan, target: "plan-header", partial: "coplan/plans/header", locals: { plan: @plan })
          end

          if permitted.key?(:title) && @plan.saved_change_to_title?
            Plans::LogEvent.call(
              plan: @plan, actor: current_user, event_type: "title_changed",
              before: old_title, after: @plan.title,
              actor_type: api_author_type, actor_id: api_actor_id
            )
          end

          if @plan.saved_change_to_visibility? && @plan.published? && old_visibility == "draft"
            Plans::LogEvent.call(
              plan: @plan, actor: current_user, event_type: "published",
              before: "draft", after: "published",
              actor_type: api_author_type, actor_id: api_actor_id
            )
            CoPlan::Analytics.track(
              "plan_published",
              user: current_user,
              plan_id: @plan.id,
              plan_type_id: @plan.plan_type_id,
              via: "api"
            )
          end

          if @plan.saved_change_to_archived_at? && @plan.archived? != old_archived
            Plans::LogEvent.call(
              plan: @plan, actor: current_user,
              event_type: @plan.archived? ? "archived" : "unarchived",
              actor_type: api_author_type, actor_id: api_actor_id
            )
          end

          if @plan.saved_change_to_folder_id?
            Plans::LogEvent.call(
              plan: @plan, actor: current_user, event_type: "moved_to_folder",
              before: old_folder_path, after: @plan.folder&.path,
              actor_type: api_author_type, actor_id: api_actor_id
            )
          end

          if params.key?(:tags)
            new_tag_names = @plan.tag_names
            (new_tag_names - old_tag_names).each do |added|
              Plans::LogEvent.call(
                plan: @plan, actor: current_user, event_type: "tag_added", after: added,
                actor_type: api_author_type, actor_id: api_actor_id
              )
            end
            (old_tag_names - new_tag_names).each do |removed|
              Plans::LogEvent.call(
                plan: @plan, actor: current_user, event_type: "tag_removed", before: removed,
                actor_type: api_author_type, actor_id: api_actor_id
              )
            end
          end

          if params[:references].is_a?(Array)
            params[:references].each do |ref_params|
              next unless ref_params[:url].present?
              ref_type = ref_params[:reference_type].presence || Reference.classify_url(ref_params[:url])
              ref = @plan.references.find_or_initialize_by(url: ref_params[:url])
              # Only emit a "reference_added" event for genuinely new references;
              # existing-reference updates fall through silently for now.
              was_new = ref.new_record?
              ref.assign_attributes(key: ref_params[:key], title: ref_params[:title], reference_type: ref_type, source: "explicit")
              ref.save!
              if was_new
                Plans::LogEvent.call(
                  plan: @plan, actor: current_user, event_type: "reference_added",
                  after: ref.url, metadata: { title: ref.title, reference_type: ref.reference_type },
                  actor_type: api_author_type, actor_id: api_actor_id
                )
              end
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

        # Index filtering. Canonical params: `visibility` (draft|published)
        # and `archived` (true opts archived plans in — they're excluded by
        # default). The legacy `status` param maps onto the same axes for
        # the deprecation window.
        def apply_index_filters(plans)
          if params[:archived].to_s == "true"
            plans = plans.archived
          elsif params[:status].present?
            plans = case params[:status]
            when "abandoned" then plans.archived
            when "brainstorm" then plans.active.where(visibility: "draft")
            else plans.active.where(visibility: "published")
            end
            return plans
          else
            plans = plans.active
          end
          plans = plans.where(visibility: params[:visibility]) if Plan::VISIBILITIES.include?(params[:visibility])
          plans
        end

        # Maps update params onto the canonical visibility/archival fields.
        # Accepts `visibility` + `archived` (canonical) and legacy `status`.
        # Publishing is one-way: an attempt to move a published plan back to
        # draft renders a 422 rather than silently unpublishing a document
        # people may have already read.
        def visibility_params_for_update
          updates = {}
          if params.key?(:status)
            updates.merge!(Plan.attributes_for_legacy_status(params[:status]))
          end
          if params.key?(:visibility)
            unless Plan::VISIBILITIES.include?(params[:visibility])
              render json: { error: "visibility must be one of: #{Plan::VISIBILITIES.join(", ")}" }, status: :unprocessable_content
              return {}
            end
            updates[:visibility] = params[:visibility]
          end
          if params.key?(:archived)
            updates[:archived_at] = params[:archived].to_s == "true" ? (@plan.archived_at || Time.current) : nil
          end

          if updates[:visibility] == "draft" && @plan.published?
            render json: { error: "Published plans cannot return to draft. Archive the plan instead." }, status: :unprocessable_content
            return {}
          end
          updates.delete(:visibility) if updates[:visibility] == @plan.visibility
          updates
        end

        # Resolves `folder_id` / `folder_path` update params to a Folder (or
        # nil to clear). `folder_path` finds-or-creates the hierarchy, which
        # is what lets an AI librarian agent organize plans into folders that
        # don't exist yet. Renders an error and returns early on bad input.
        def resolve_folder_params
          if params[:folder_id].present?
            folder = Folder.find_by(id: params[:folder_id])
            render json: { error: "Unknown folder_id" }, status: :unprocessable_content unless folder
            folder
          elsif params[:folder_path].present?
            Folder.find_or_create_by_path!(params[:folder_path], created_by_user: current_user)
          else
            nil # blank folder_id / folder_path clears the folder
          end
        end

        def plan_json(plan)
          {
            id: plan.id,
            title: plan.title,
            visibility: plan.visibility,
            archived: plan.archived?,
            archived_at: plan.archived_at,
            # Legacy five-state field, kept for the deprecation window.
            status: plan.legacy_status,
            current_revision: plan.current_revision,
            tags: plan.tag_names,
            folder_id: plan.folder_id,
            folder_path: plan.folder&.path,
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
          json = {
            id: collaborator.id,
            user: user_json(collaborator.user),
            role: collaborator.role
          }
          json[:approved_at] = collaborator.approved_at if collaborator.role == "approver"
          json[:highlighted_reason] = collaborator.highlighted_reason if collaborator.role == "highlighted"
          json
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
          return nil unless thread.anchored?
          return 0 unless content.present? && thread.anchor_start.present? && stripped_data

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
