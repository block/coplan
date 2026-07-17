module CoPlan
  class PlansController < ApplicationController
    before_action :set_plan, only: [:show, :edit, :update, :publish, :archive, :unarchive, :move_to_folder, :toggle_checkbox, :history, :edit_content, :update_content, :preview]

    PER_PAGE = 20

    SCOPES = %w[mine all].freeze
    DEFAULT_SCOPE = "mine".freeze

    # Display order for the main-pane groups: published work first, then the
    # viewer's unlisted drafts. Archived plans are opt-in (?filter=archived)
    # and never render as a default group.
    GROUP_ORDER = %w[published draft].freeze
    FILTERS = %w[published draft archived].freeze

    # Sidebar workspace index. Two rendering modes:
    #
    # - Grouped (default): collapsible published/draft groups, each with its
    #   own "load more" turbo-frame pagination (frames carry group + filter
    #   params back here).
    # - Flat: when ?filter= narrows to one group (or opts into archived),
    #   one recency-sorted paginated list.
    #
    # Turbo-frame requests are always page fetches for one of those lists
    # and render only the row page partial.
    def index
      @scope = SCOPES.include?(params[:scope]) ? params[:scope] : DEFAULT_SCOPE
      @filter = FILTERS.include?(params[:filter]) ? params[:filter] : nil
      load_folder_tree

      if params[:folder].present?
        @folder = @folders_by_id[params[:folder]]
        if @folder.nil? && !turbo_frame_request?
          redirect_to plans_path(params.permit(:scope, :filter, :plan_type, :tag).to_h),
            alert: "That folder no longer exists."
          return
        end
      end

      plans = scoped_plans_base.includes(:plan_type, :tags, :created_by_user, :current_plan_version)

      plans = plans.where(plan_type_id: params[:plan_type]) if params[:plan_type].present?
      plans = plans.with_tag(params[:tag]) if params[:tag].present?
      # A folder filter includes its subfolders — clicking "Team EBT" shows
      # everything under it. Folder ids come from the viewer's own library
      # tree, so the placement join is already library-scoped.
      if @folder
        plans = plans.joins(:placements)
          .where(coplan_plan_placements: { folder_id: folder_subtree_ids(@folder) })
      end
      # Stale frame fetch for a since-deleted folder: render an empty page.
      plans = plans.none if params[:folder].present? && @folder.nil?

      if @filter.present? || turbo_frame_request?
        plans = filtered_plans(plans, @filter)
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
              frame_filter: @filter
            },
            layout: false
          return
        end
      else
        active = plans.active
        @group_counts = active.group(:visibility).count
        @archived_count = plans.archived.count
        @groups = GROUP_ORDER.filter_map do |visibility|
          count = @group_counts[visibility].to_i
          next if count.zero?

          group_plans = active.where(visibility: visibility)
            .order(updated_at: :desc, id: :desc)
            .limit(PER_PAGE + 1).to_a
          {
            group: visibility,
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
    # "Move to folder" fallback. Shelves the plan in the current user's own
    # library — any visible plan can be shelved, not just your own
    # (Plans::Place enforces both sides).
    def move_to_folder
      folder = nil
      if params[:folder_id].present?
        folder = current_user.library.folders.find_by(id: params[:folder_id])
        unless folder
          respond_to do |format|
            format.json { render json: { error: "Unknown folder" }, status: :unprocessable_content }
            format.html { redirect_back fallback_location: plans_path, alert: "Unknown folder." }
          end
          return
        end
      end

      result = Plans::Place.call(plan: @plan, folder: folder, actor: current_user)
      unless result.success?
        respond_to do |format|
          format.json { render json: { error: result.error }, status: :unprocessable_content }
          format.html { redirect_back fallback_location: plans_path, alert: result.error }
        end
        return
      end

      notice = folder ? "Moved “#{@plan.title}” to #{folder.path}." : "Removed “#{@plan.title}” from its folder."
      respond_to do |format|
        format.json do
          render json: {
            folder_id: result.placement&.folder_id,
            folder_path: result.placement&.folder&.path,
            message: notice
          }
        end
        format.html { redirect_back fallback_location: plans_path, notice: notice }
      end
    end

    def show
      authorize!(@plan, :show?)
      # Folder-jump discovery: every shelf this plan sits on. The plan
      # itself is already authorized above, and placements inherit the
      # plan's visibility — a shelf never reveals more than the plan does.
      @shelf_placements = @plan.placements
        .includes(:library, folder: { parent: :parent })
        .sort_by { |p| p.created_at }
      @my_folders = current_user.library.folders.order(:name).to_a
      @threads = @plan.comment_threads.with_kept_comments.includes(:comments, :created_by_user).order(:created_at)
      @references = @plan.references.order(reference_type: :asc, created_at: :desc)
      @attachments = @plan.attachments_attachments.includes(:blob).order(created_at: :desc)
      PlanViewer.track(plan: @plan, user: current_user)
    end

    def history
      authorize!(@plan, :show?)
      @history_items = @plan.history_items
      render layout: false
    end

    def edit
      authorize!(@plan, :update?)
      # Datalist suggestions for the tag chip editor — reusing an existing
      # tag beats coining a near-duplicate.
      @tag_suggestions = CoPlan::Tag.order(:name).limit(200).pluck(:name)
    end

    def update
      authorize!(@plan, :update?)
      old_title = @plan.title
      old_tag_names = @plan.tag_names
      new_title = params[:plan][:title]

      if params[:plan].key?(:tag_names)
        @plan.tag_names = params[:plan][:tag_names].to_s.split(",")
      end
      @plan.update!(title: new_title)

      if @plan.saved_change_to_title?
        Plans::LogEvent.call(
          plan: @plan,
          actor: current_user,
          event_type: "title_changed",
          before: old_title,
          after: new_title
        )
      end

      new_tag_names = @plan.tag_names
      (new_tag_names - old_tag_names).each do |added|
        Plans::LogEvent.call(plan: @plan, actor: current_user, event_type: "tag_added", after: added)
      end
      (old_tag_names - new_tag_names).each do |removed|
        Plans::LogEvent.call(plan: @plan, actor: current_user, event_type: "tag_removed", before: removed)
      end

      broadcast_plan_update(@plan)
      redirect_to plan_path(@plan), notice: "Plan updated."
    end

    def edit_content
      authorize!(@plan, :edit_content?)
      @draft_content = @plan.current_content
      @base_revision = @plan.current_revision
    end

    # Human whole-document editing goes through the same pipeline as agent
    # edits: Plans::ReplaceContent diffs against the base revision, creates
    # an immutable PlanVersion with actor_type "human", preserves comment
    # anchors in unchanged regions, and broadcasts the new body. Optimistic
    # concurrency: a stale base_revision re-renders the editor with the
    # user's draft intact instead of clobbering intervening edits.
    def update_content
      authorize!(@plan, :edit_content?)

      # After a conflict, the form keeps its stale base_revision so an
      # unreviewed re-save fails loudly again instead of silently clobbering
      # the intervening edit. "Save anyway" submits overwrite_revision —
      # explicit consent to replace that specific revision; if the plan has
      # moved on again since, this still conflicts.
      base_revision = (params[:overwrite_revision].presence || params[:base_revision]).to_i

      result = Plans::ReplaceContent.call(
        plan: @plan,
        new_content: params[:content].to_s,
        base_revision: base_revision,
        actor_type: "human",
        actor_id: current_user.id,
        change_summary: params[:change_summary].presence || "Edited in web UI"
      )

      if result[:no_op]
        redirect_to plan_path(@plan), notice: "No changes to save."
      else
        redirect_to plan_path(@plan), notice: "Plan content updated."
      end
    rescue Plans::ReplaceContent::StaleRevisionError => e
      @draft_content = params[:content].to_s
      @base_revision = params[:base_revision].to_i
      @conflict_revision = e.current_revision
      @conflict = true
      flash.now[:alert] = "This plan was updated to v#{e.current_revision} while you were editing. " \
                          "Your draft is preserved below — review the latest version before saving again."
      render :edit_content, status: :conflict
    end

    # Renders submitted markdown for the editor's preview pane. Non-interactive
    # render: no checkbox wiring, since the content isn't saved yet.
    def preview
      authorize!(@plan, :show?)
      html = helpers.render_markdown(params[:content].to_s, interactive: false)
      render html: html, layout: false
    end

    # Publishing is the one-way door out of draft: explicit, confirmed in
    # the UI, and irreversible by design (archive is the tool for "done
    # with this", not unpublish).
    def publish
      authorize!(@plan, :publish?)
      @plan.update!(visibility: "published")
      broadcast_plan_update(@plan)
      Plans::LogEvent.call(
        plan: @plan,
        actor: current_user,
        event_type: "published",
        before: "draft",
        after: "published"
      )
      CoPlan::Analytics.track(
        "plan_published",
        user: current_user,
        plan_id: @plan.id,
        plan_type_id: @plan.plan_type_id,
        via: "web"
      )
      redirect_to plan_path(@plan), notice: "Plan published — everyone can see it now."
    end

    def archive
      authorize!(@plan, :archive?)
      @plan.update!(archived_at: Time.current)
      broadcast_plan_update(@plan)
      Plans::LogEvent.call(plan: @plan, actor: current_user, event_type: "archived")
      redirect_to plan_path(@plan), notice: "Plan archived. It's hidden from lists unless someone filters for archived plans."
    end

    def unarchive
      authorize!(@plan, :unarchive?)
      @plan.update!(archived_at: nil)
      broadcast_plan_update(@plan)
      Plans::LogEvent.call(plan: @plan, actor: current_user, event_type: "unarchived")
      redirect_to plan_path(@plan), notice: "Plan restored."
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

      checkbox_pattern = MarkdownHelper::TASK_LINE_PATTERN
      unless old_text.match?(checkbox_pattern) && new_text.match?(checkbox_pattern)
        render json: { error: "old_text and new_text must be task list items" }, status: :unprocessable_content
        return
      end

      # Optional 1-based source line carried by the rendered checkbox
      # (data-line). The line's text must equal old_text, so duplicate task
      # lines elsewhere can't collide and a stale client fails loudly
      # instead of toggling a lookalike.
      line = nil
      if params[:line].present?
        line = Integer(params[:line], exception: false)
        if line.nil? || line < 1
          render json: { error: "line must be a positive integer" }, status: :unprocessable_content
          return
        end
      end

      ActiveRecord::Base.transaction do
        @plan.lock!
        @plan.reload

        if @plan.current_revision != base_revision
          render json: { error: "Conflict", current_revision: @plan.current_revision }, status: :conflict
          return
        end

        current_content = @plan.current_content || ""
        operation = { "op" => "replace_exact", "old_text" => old_text, "new_text" => new_text }
        if line
          occurrence = occurrence_at_line(current_content, old_text, line)
          if occurrence.nil?
            render json: { error: "old_text does not match line #{line}", current_revision: @plan.current_revision }, status: :unprocessable_content
            return
          end
          operation["occurrence"] = occurrence
        end
        result = Plans::ApplyOperations.call(
          content: current_content,
          operations: [operation]
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

    # Narrows a relation to one workspace filter. Archived plans are opt-in
    # everywhere: no filter means active plans only.
    def filtered_plans(plans, filter)
      case filter
      when "archived" then plans.archived
      when "draft", "published" then plans.active.where(visibility: filter)
      else plans.active
      end
    end

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
        # The workspace is your plans *and* your placements — a plan you
        # shelved from someone else belongs on your operating surface too.
        base = Plan.visible_to(current_user)
        base.where(created_by_user_id: current_user.id)
          .or(base.where(id: current_user.library.placements.select(:plan_id)))
      else
        # Draft plans are private — never show other users'.
        Plan.visible_to(current_user)
      end
    end

    # One query for the viewer's whole library tree; everything else
    # (children map, subtree ids, expanded state, aggregate counts) is
    # derived in memory.
    def load_folder_tree
      @library = current_user.library
      @folders = @library.folders.order(:name).to_a
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
    # which also means other users’ unlisted drafts never surface
    # through folder counts or tag lists (Plan.visible_to).
    def load_workspace_sidebar
      # Archived plans are hidden from default lists, so they're excluded
      # from folder/tag counts too — counts always match what clicking shows.
      direct_counts = scoped_plans_base.active
        .joins(:placements)
        .where(coplan_plan_placements: { library_id: @library.id })
        .group("coplan_plan_placements.folder_id")
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
        .where(coplan_plan_tags: { plan_id: scoped_plans_base.active.select(:id) })
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

    # Maps a verified (line, old_text) pair to the occurrence ordinal the
    # position resolver will select, keeping the toggle a plain
    # replace_exact. Returns nil unless the line's rstripped text is exactly
    # old_text — line and text must both agree for the edit to land.
    def occurrence_at_line(content, old_text, line)
      lines = content.each_line.to_a
      return nil if line > lines.length
      return nil unless lines[line - 1].rstrip == old_text

      line_start = lines.first(line - 1).sum(&:length)
      occurrence = 1
      pos = 0
      while (idx = content.index(old_text, pos)) && idx < line_start
        occurrence += 1
        pos = idx + old_text.length
      end
      occurrence
    end

    def set_plan
      @plan = Plan.find(params[:id])
    end

    def broadcast_plan_update(plan)
      Broadcaster.replace_to(plan, target: "plan-header", partial: "coplan/plans/header", locals: { plan: plan })
    end
  end
end
