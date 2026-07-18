module CoPlan
  class PlansController < ApplicationController
    before_action :set_plan, only: [:show, :edit, :update, :publish, :archive, :unarchive, :move_to_folder, :toggle_checkbox, :history, :edit_content, :update_content, :preview]

    PER_PAGE = 20

    SCOPES = %w[mine all].freeze
    DEFAULT_SCOPE = "mine".freeze

    FILTERS = %w[published draft archived].freeze

    # Sidebar workspace index. Two rendering modes:
    #
    # - Grouped (default): the viewer's filing tree as collapsible groups —
    #   one per root folder (containing its whole subtree) plus "Unfiled" —
    #   topped by a "since you last looked" strip. Each group has its own
    #   "load more" turbo-frame pagination (frames carry group + folder +
    #   filter params back here).
    # - Flat: when ?filter= or ?folder= narrows the view, one recency-sorted
    #   paginated list.
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
      # Page fetches for the "Unfiled" group: plans not shelved anywhere in
      # the viewer's library.
      plans = plans.where.not(id: @library.placements.select(:plan_id)) if params[:group] == "unfiled"

      if @filter.present? || @folder.present? || turbo_frame_request?
        plans = filtered_plans(plans, @filter)
        plans = plans.order(updated_at: :desc, id: :desc)

        @page = [ params[:page].to_i, 1 ].max
        # to_a first: sizing the unloaded relation would issue an extra COUNT.
        page_rows = plans.limit(PER_PAGE + 1).offset((@page - 1) * PER_PAGE).to_a
        @has_next_page = page_rows.size > PER_PAGE
        @plans = page_rows.first(PER_PAGE)
        @plan_unread_counts = unread_counts_for(@plans)

        if turbo_frame_request?
          render partial: "coplan/plans/plan_page",
            locals: {
              plans: @plans,
              plan_unread_counts: @plan_unread_counts,
              page: @page,
              has_next_page: @has_next_page,
              group_key: params[:group].presence || "results",
              frame_filter: @filter,
              frame_folder: params[:folder].presence
            },
            layout: false
          return
        end
      else
        active = plans.active
        @archived_count = plans.archived.count
        @groups = folder_groups_for(active)
        @plan_unread_counts = unread_counts_for(@groups.flat_map { |g| g[:plans] })
        load_recently_updated
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
        .order(:created_at)
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

    # The separate title-and-tags page merged into the unified editor —
    # keep the route working for old links.
    def edit
      authorize!(@plan, :update?)
      redirect_to edit_content_plan_path(@plan)
    end

    def update
      authorize!(@plan, :update?)
      # expect (Rails 8) turns a malformed payload into a 400, not a 500.
      plan_params = params.expect(plan: [ :title, :tag_names ])
      apply_metadata_changes!(
        title: plan_params[:title],
        tag_names: plan_params.key?(:tag_names) ? plan_params[:tag_names] : nil
      )
      broadcast_plan_update(@plan)
      redirect_to plan_path(@plan), notice: "Plan updated."
    end

    def edit_content
      authorize!(@plan, :edit_content?)
      @draft_content = @plan.current_content
      @base_revision = @plan.current_revision
      load_tag_suggestions
    end

    # Human whole-document editing goes through the same pipeline as agent
    # edits: Plans::ReplaceContent diffs against the base revision, creates
    # an immutable PlanVersion with actor_type "human", preserves comment
    # anchors in unchanged regions, and broadcasts the new body. Optimistic
    # concurrency: a stale base_revision re-renders the editor with the
    # user's draft intact instead of clobbering intervening edits.
    def update_content
      authorize!(@plan, :edit_content?)

      # The editor is the one place a plan gets edited, so it carries
      # title/tags too. Metadata isn't revisioned — apply it up front, even
      # if the content save below hits a conflict (a rename shouldn't be
      # lost to someone else's body edit).
      metadata_changed = if params[:plan].present?
        plan_params = params.expect(plan: [ :title, :tag_names ])
        apply_metadata_changes!(
          title: plan_params[:title],
          tag_names: plan_params.key?(:tag_names) ? plan_params[:tag_names] : nil
        )
      else
        false
      end
      broadcast_plan_update(@plan) if metadata_changed

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
        notice = metadata_changed ? "Plan updated." : "No changes to save."
        redirect_to plan_path(@plan), notice: notice
      else
        redirect_to plan_path(@plan), notice: "Plan updated."
      end
    rescue Plans::ReplaceContent::StaleRevisionError => e
      @draft_content = params[:content].to_s
      @base_revision = params[:base_revision].to_i
      @conflict_revision = e.current_revision
      @conflict = true
      load_tag_suggestions
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
      # (data-line); the service verifies line and text agree.
      line = nil
      if params[:line].present?
        line = Integer(params[:line], exception: false)
        if line.nil? || line < 1
          render json: { error: "line must be a positive integer" }, status: :unprocessable_content
          return
        end
      end

      Plans::ToggleCheckbox.call(
        plan: @plan,
        old_text: old_text,
        new_text: new_text,
        base_revision: base_revision,
        actor_id: current_user.id,
        line: line
      )

      render json: { revision: @plan.current_revision }
    rescue Plans::ReplaceContent::StaleRevisionError => e
      render json: { error: "Conflict", current_revision: e.current_revision }, status: :conflict
    rescue Plans::ToggleCheckbox::LineMismatchError => e
      render json: { error: e.message, current_revision: e.current_revision }, status: :unprocessable_content
    rescue Plans::OperationError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    private

    # Title/tag updates with their audit events — shared by the metadata
    # PATCH (#update) and the unified editor (#update_content). Returns
    # true when anything actually changed.
    def apply_metadata_changes!(title:, tag_names:)
      old_title = @plan.title
      old_tag_names = @plan.tag_names

      @plan.tag_names = tag_names.to_s.split(",") unless tag_names.nil?
      @plan.update!(title: title) if title.present?

      changed = false
      if @plan.saved_change_to_title?
        changed = true
        Plans::LogEvent.call(
          plan: @plan,
          actor: current_user,
          event_type: "title_changed",
          before: old_title,
          after: @plan.title
        )
      end

      new_tag_names = @plan.tag_names
      (new_tag_names - old_tag_names).each do |added|
        changed = true
        Plans::LogEvent.call(plan: @plan, actor: current_user, event_type: "tag_added", after: added)
      end
      (old_tag_names - new_tag_names).each do |removed|
        changed = true
        Plans::LogEvent.call(plan: @plan, actor: current_user, event_type: "tag_removed", before: removed)
      end
      changed
    end

    # Main-pane groups mirror the sidebar's filing tree: one collapsible
    # group per root folder (spanning its whole subtree), plus "Unfiled"
    # for plans not shelved anywhere in the viewer's library. Grouping is
    # viewer-relative — the same plan sits on different shelves for
    # different people. Drafts aren't a separate group; draft rows carry
    # their own quiet flag wherever they're filed.
    def folder_groups_for(active)
      # One grouped count for all folders (these counts respect the active
      # plan_type/tag params, so they can't be shared with the sidebar's).
      # Per-group page queries below only run for non-empty groups.
      direct_counts = active.joins(:placements)
        .where(coplan_plan_placements: { library_id: @library.id })
        .group("coplan_plan_placements.folder_id")
        .count

      groups = @root_folders.filter_map do |folder|
        subtree_ids = folder_subtree_ids(folder)
        count = subtree_ids.sum { |id| direct_counts.fetch(id, 0) }
        next if count.zero?

        subtree = active.joins(:placements)
          .where(coplan_plan_placements: { library_id: @library.id, folder_id: subtree_ids })
        page = subtree.order(updated_at: :desc, id: :desc).limit(PER_PAGE + 1).to_a
        {
          key: "folder-#{folder.id}",
          folder: folder,
          label: folder.name,
          count: count,
          plans: page.first(PER_PAGE),
          has_next_page: page.size > PER_PAGE
        }
      end

      unfiled = active.where.not(id: @library.placements.select(:plan_id))
      count = unfiled.count
      if count.positive?
        page = unfiled.order(updated_at: :desc, id: :desc).limit(PER_PAGE + 1).to_a
        groups << {
          key: "unfiled",
          folder: nil,
          label: "Unfiled",
          count: count,
          plans: page.first(PER_PAGE),
          has_next_page: page.size > PER_PAGE
        }
      end
      groups
    end

    RECENT_LIMIT = 5
    RECENT_CANDIDATES = 30

    # "Since you last looked": plans that changed after the viewer's last
    # visit, or that they've never opened and didn't write. Derived from
    # PlanViewer.last_seen_at — recency against your own reading history,
    # not workflow state. Bounded: only the newest RECENT_CANDIDATES are
    # considered, and at most RECENT_LIMIT surface.
    def load_recently_updated
      candidates = scoped_plans_base.active
        .includes(:created_by_user)
        .order(updated_at: :desc, id: :desc)
        .limit(RECENT_CANDIDATES)
      last_seen = PlanViewer.where(user: current_user, plan_id: candidates.map(&:id))
        .pluck(:plan_id, :last_seen_at).to_h

      @recent_updates = candidates.filter_map do |plan|
        seen_at = last_seen[plan.id]
        if seen_at.nil?
          # Your own unvisited plan is just a plan you made elsewhere (API,
          # agent) — not news.
          next if plan.created_by_user_id == current_user.id
          { plan: plan, badge: "new to you" }
        elsif plan.updated_at > seen_at
          { plan: plan, badge: "updated" }
        end
      end.first(RECENT_LIMIT)
    end

    # Narrows a relation to one workspace filter. Archived plans are opt-in
    # everywhere: no filter means active plans only.
    def filtered_plans(plans, filter)
      case filter
      when "archived" then plans.archived
      when "draft", "published" then plans.active.where(visibility: filter)
      else plans.active
      end
    end

    # The editor also edits title/tags; suggestions for the tag chips —
    # reusing an existing tag beats coining a near-duplicate.
    def load_tag_suggestions
      @tag_suggestions = CoPlan::Tag.order(:name).limit(200).pluck(:name)
    end

    # One grouped query per request, shared between the per-row unread
    # badges and the "needs attention" strip.
    def unread_by_plan
      @unread_by_plan ||= current_user.notifications.unread.group(:plan_id).count
    end

    def unread_counts_for(plans)
      unread_by_plan.slice(*plans.map(&:id))
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
      @attention_unread_counts = unread_by_plan
      top_ids = unread_by_plan.sort_by { |_id, count| -count }
        .first(ATTENTION_LIMIT).map(&:first)
      # Even an inbox routes through the discovery predicate — a stale
      # notification must not resurface an archived plan or another user's
      # unlisted draft.
      @attention_plans = Plan.visible_to(current_user).active.where(id: top_ids)
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
