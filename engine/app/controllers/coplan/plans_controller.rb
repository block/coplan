module CoPlan
  class PlansController < ApplicationController
    before_action :set_plan, only: [ :show, :edit, :update, :update_status, :move_to_folder, :toggle_checkbox, :history ]

    PER_PAGE = 20

    SCOPES = %w[mine all].freeze
    DEFAULT_SCOPE = "mine".freeze

    # Display order for the main-pane status groups: active work first,
    # brainstorms (collapsed by default) and abandoned plans last.
    STATUS_GROUP_ORDER = %w[developing considering live brainstorm abandoned].freeze

    # Sidebar workspace index. Two rendering modes:
    #
    # - Grouped (default): collapsible status groups, each with its own
    #   "load more" turbo-frame pagination (frames carry group + status
    #   params back here).
    # - Flat: when ?status= filters to a single status, one recency-sorted
    #   paginated list.
    #
    # Turbo-frame requests are always page fetches for one of those lists
    # and render only the row page partial.
    def index
      @scope = SCOPES.include?(params[:scope]) ? params[:scope] : DEFAULT_SCOPE
      load_folder_tree

      if params[:folder].present?
        @folder = @folders_by_id[params[:folder]]
        if @folder.nil? && !turbo_frame_request?
          redirect_to plans_path(params.permit(:scope, :status, :plan_type, :tag).to_h),
            alert: "That folder no longer exists."
          return
        end
      end

      plans = scoped_plans_base.includes(:plan_type, :tags, :created_by_user, :current_plan_version, :folder)

      plans = plans.where(plan_type_id: params[:plan_type]) if params[:plan_type].present?
      plans = plans.with_tag(params[:tag]) if params[:tag].present?
      # A folder filter includes its subfolders — clicking "Team EBT" shows
      # everything under it.
      plans = plans.where(folder_id: folder_subtree_ids(@folder)) if @folder
      # Stale frame fetch for a since-deleted folder: render an empty page.
      plans = plans.none if params[:folder].present? && @folder.nil?

      if params[:status].present? || turbo_frame_request?
        plans = plans.where(status: params[:status]) if params[:status].present?
        plans = plans.order(updated_at: :desc, id: :desc)

        @page = [ params[:page].to_i, 1 ].max
        @plans = plans.limit(PER_PAGE + 1).offset((@page - 1) * PER_PAGE)
        @has_next_page = @plans.size > PER_PAGE
        @plans = @plans.first(PER_PAGE)
        @plan_unread_counts = unread_counts_for(@plans)

        if turbo_frame_request?
          render partial: "coplan/plans/plan_page",
            locals: {
              plans: @plans,
              plan_unread_counts: @plan_unread_counts,
              page: @page,
              has_next_page: @has_next_page,
              group_key: params[:group].presence || "results",
              frame_status: params[:status].presence
            },
            layout: false
          return
        end
      else
        @group_counts = plans.group(:status).count
        @groups = STATUS_GROUP_ORDER.filter_map do |status|
          count = @group_counts[status].to_i
          next if count.zero?

          group_plans = plans.where(status: status)
            .order(updated_at: :desc, id: :desc)
            .limit(PER_PAGE + 1).to_a
          {
            status: status,
            count: count,
            plans: group_plans.first(PER_PAGE),
            has_next_page: group_plans.size > PER_PAGE
          }
        end
        @plan_unread_counts = unread_counts_for(@groups.flat_map { |g| g[:plans] })
      end

      load_workspace_sidebar
      load_needs_attention
      @plan_types = PlanType.order(:name)
      @show_onboarding_banner = CoPlan.configuration.onboarding_banner.present? &&
        !current_user.created_plans.exists?
    end

    # Web endpoint behind the sidebar drag-and-drop and the row-menu
    # "Move to folder" fallback. Author-only (PlanPolicy#update?).
    def move_to_folder
      authorize!(@plan, :update?)

      folder = nil
      if params[:folder_id].present?
        folder = Folder.find_by(id: params[:folder_id])
        unless folder
          respond_to do |format|
            format.json { render json: { error: "Unknown folder" }, status: :unprocessable_content }
            format.html { redirect_back fallback_location: plans_path, alert: "Unknown folder." }
          end
          return
        end
      end

      if @plan.folder_id != folder&.id
        old_path = @plan.folder&.path
        @plan.update!(folder: folder)
        Plans::LogEvent.call(
          plan: @plan,
          actor: current_user,
          event_type: "moved_to_folder",
          before: old_path,
          after: folder&.path
        )
      end

      notice = folder ? "Moved “#{@plan.title}” to #{folder.path}." : "Removed “#{@plan.title}” from its folder."
      respond_to do |format|
        format.json { render json: { folder_id: @plan.folder_id, folder_path: @plan.folder&.path, message: notice } }
        format.html { redirect_back fallback_location: plans_path, notice: notice }
      end
    end

    def show
      authorize!(@plan, :show?)
      @threads = @plan.comment_threads.with_kept_comments.includes(:comments, :created_by_user).order(:created_at)
      @references = @plan.references.order(reference_type: :asc, created_at: :desc)
      PlanViewer.track(plan: @plan, user: current_user)
    end

    def history
      authorize!(@plan, :show?)
      @history_items = @plan.history_items
      render layout: false
    end

    def edit
      authorize!(@plan, :update?)
    end

    def update
      authorize!(@plan, :update?)
      old_title = @plan.title
      new_title = params[:plan][:title]
      @plan.update!(title: new_title)
      Plans::LogEvent.call(
        plan: @plan,
        actor: current_user,
        event_type: "title_changed",
        before: old_title,
        after: new_title
      )
      broadcast_plan_update(@plan)
      redirect_to plan_path(@plan), notice: "Plan updated."
    end

    def update_status
      authorize!(@plan, :update_status?)
      new_status = params[:status]
      old_status = @plan.status
      if Plan::STATUSES.include?(new_status) && @plan.update(status: new_status)
        broadcast_plan_update(@plan)
        if @plan.saved_change_to_status?
          Plans::LogEvent.call(
            plan: @plan,
            actor: current_user,
            event_type: "status_changed",
            before: old_status,
            after: new_status
          )
          if new_status == "considering" && old_status != "considering"
            CoPlan::Analytics.track(
              "plan_published",
              user: current_user,
              plan_id: @plan.id,
              plan_type_id: @plan.plan_type_id,
              previous_status: old_status,
              via: "web"
            )
          end
        end
        redirect_to plan_path(@plan), notice: "Status updated to #{new_status}."
      else
        redirect_to plan_path(@plan), alert: "Invalid status."
      end
    end

    def toggle_checkbox
      authorize!(@plan, :show?)

      old_text = params[:old_text]
      new_text = params[:new_text]
      base_revision = params[:base_revision]&.to_i

      unless old_text.present? && new_text.present? && base_revision.present?
        render json: { error: "old_text, new_text, and base_revision are required" }, status: :unprocessable_content
        return
      end

      checkbox_pattern = /\A\s*[*+-]\s+\[[ xX]\]\s/
      unless old_text.match?(checkbox_pattern) && new_text.match?(checkbox_pattern)
        render json: { error: "old_text and new_text must be task list items" }, status: :unprocessable_content
        return
      end

      ActiveRecord::Base.transaction do
        @plan.lock!
        @plan.reload

        if @plan.current_revision != base_revision
          render json: { error: "Conflict", current_revision: @plan.current_revision }, status: :conflict
          return
        end

        current_content = @plan.current_content || ""
        result = Plans::ApplyOperations.call(
          content: current_content,
          operations: [ { "op" => "replace_exact", "old_text" => old_text, "new_text" => new_text } ]
        )

        new_revision = @plan.current_revision + 1
        diff = Diffy::Diff.new(current_content, result[:content]).to_s

        version = PlanVersion.create!(
          plan: @plan,
          revision: new_revision,
          content_markdown: result[:content],
          actor_type: "human",
          actor_id: current_user.id,
          change_summary: "Toggle checkbox",
          diff_unified: diff.presence,
          operations_json: result[:applied],
          base_revision: base_revision
        )

        @plan.update!(current_plan_version: version, current_revision: new_revision)
        @plan.comment_threads.mark_out_of_date_for_new_version!(version)
      end

      broadcast_plan_update(@plan)
      Broadcaster.replace_plan_content(@plan)
      render json: { revision: @plan.current_revision }
    rescue Plans::OperationError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    private

    def unread_counts_for(plans)
      current_user.notifications.unread
        .where(plan_id: plans.map(&:id))
        .group(:plan_id)
        .count
    end

    # The base relation for the active workspace scope. Used by both the
    # main-pane plan lists and the sidebar counts so folder/tag counts
    # always match what clicking through shows.
    def scoped_plans_base
      if @scope == "mine"
        Plan.where(created_by_user: current_user)
      else
        # Brainstorm plans are private drafts — never show other users'.
        Plan.visible_to(current_user)
      end
    end

    # One query for the whole folder tree; everything else (children map,
    # subtree ids, expanded state, aggregate counts) is derived in memory.
    def load_folder_tree
      @folders = Folder.order(:name).to_a
      @folders_by_id = @folders.index_by(&:id)
      @folder_children = @folders.group_by(&:parent_id)
      @root_folders = @folder_children[nil] || []
    end

    # Ids of a folder plus all folders nested under it, walked over the
    # in-memory tree (the visited check doubles as a cycle guard).
    def folder_subtree_ids(folder)
      ids = []
      queue = [ folder.id ]
      while (id = queue.shift)
        next if ids.include?(id)
        ids << id
        queue.concat((@folder_children[id] || []).map(&:id))
      end
      ids
    end

    # Sidebar data: the folder tree with per-folder plan counts, and the
    # most-used tags. Counts and tag usage use the same base relation as
    # the main pane (scoped_plans_base) so they match what clicking shows —
    # which also means other users' private brainstorm plans never leak
    # through folder counts or tag lists (Plan.visible_to).
    def load_workspace_sidebar
      direct_counts = scoped_plans_base
        .where.not(folder_id: nil)
        .group(:folder_id)
        .count
      # Displayed counts include subfolders, matching what clicking the
      # folder shows.
      @folder_counts = @folders.index_with do |folder|
        folder_subtree_ids(folder).sum { |id| direct_counts.fetch(id, 0) }
      end.transform_keys(&:id)

      # Folder nodes rendered expanded: the active folder and its ancestors.
      @open_folder_ids = Set.new
      node = @folder
      while node && @open_folder_ids.add?(node.id)
        node = @folders_by_id[node.parent_id]
      end

      @top_tags = Tag
        .joins(:plan_tags)
        .where(coplan_plan_tags: { plan_id: scoped_plans_base.select(:id) })
        .group("coplan_tags.id", "coplan_tags.name")
        .order(Arel.sql("COUNT(*) DESC"), "coplan_tags.name ASC")
        .limit(8)
        .count
        .map { |(_id, name), count| [ name, count ] }
    end

    ATTENTION_LIMIT = 5

    # "Needs attention" strip: plans with unread comment notifications for
    # the current user, most-unread first. Independent of the active
    # sidebar filters — it's an inbox, not a search result. Bounded: only
    # the top ATTENTION_LIMIT plans are loaded.
    def load_needs_attention
      unread_by_plan = current_user.notifications.unread.group(:plan_id).count
      @attention_unread_counts = unread_by_plan
      top_ids = unread_by_plan.sort_by { |_id, count| -count }
        .first(ATTENTION_LIMIT).map(&:first)
      @attention_plans = Plan.where(id: top_ids)
        .sort_by { |plan| -unread_by_plan.fetch(plan.id, 0) }
    end

    def set_plan
      @plan = Plan.find(params[:id])
    end

    def broadcast_plan_update(plan)
      Broadcaster.replace_to(plan, target: "plan-header", partial: "coplan/plans/header", locals: { plan: plan })
    end
  end
end
