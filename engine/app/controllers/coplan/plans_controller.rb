module CoPlan
  class PlansController < ApplicationController
    before_action :set_plan, only: [:show, :edit, :update, :publish, :hide, :archive, :unarchive, :move_to_folder, :toggle_checkbox, :history, :edit_content, :update_content, :preview]

    PER_PAGE = 20

    SCOPES = %w[mine all].freeze
    DEFAULT_SCOPE = "mine".freeze

    # "private" is the user-facing name; "draft" is the stored visibility
    # value and stays accepted so old links keep working.
    FILTERS = %w[published draft private archived].freeze
    UPDATED_WINDOWS = { "7d" => 7.days, "30d" => 30.days }.freeze

    # Sidebar workspace index — a Drive-style file browser. Two modes:
    #
    # - Level view (default): the current folder's contents — its direct
    #   subfolders (even empty ones) plus the plans filed directly in it.
    #   Root level shows root folders plus plans not filed anywhere.
    #   Breadcrumbs navigate up; clicking a folder goes down.
    # - Flat results: when ?filter=/?tag=/?plan_type=/?updated= narrows the
    #   view, one recency-sorted paginated list over the current folder's
    #   whole subtree (or everything, at root).
    #
    # Turbo-frame requests are page fetches for one of those lists and
    # render only the row page partial (`group` param: "level" pages the
    # direct-placement list, anything else the flat results).
    def index
      @scope = SCOPES.include?(params[:scope]) ? params[:scope] : DEFAULT_SCOPE
      @filter = FILTERS.include?(params[:filter]) ? params[:filter] : nil
      @filter = "draft" if @filter == "private"
      @updated_window = UPDATED_WINDOWS[params[:updated]] && params[:updated]
      load_folder_tree

      if params[:folder].present?
        @folder = @folders_by_id[params[:folder]]
        if @folder.nil? && !turbo_frame_request?
          redirect_to plans_path(params.permit(:scope, :filter, :plan_type, :tag, :updated).to_h),
            alert: "That folder no longer exists."
          return
        end
      end

      plans = scoped_plans_base.includes(:plan_type, :tags, :created_by_user, :current_version_stub)
      plans = apply_workspace_filters(plans)
      # Stale frame fetch for a since-deleted folder: render an empty page.
      plans = plans.none if params[:folder].present? && @folder.nil?

      if filtered_view? || turbo_frame_request?
        plans = if params[:group] == "level" || (!filtered_view? && turbo_frame_request?)
          # Page fetch for the level view: direct placements only.
          placed_directly_in(plans, @folder)
        else
          in_folder_subtree(plans, @folder)
        end
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
        # Level view: this folder's subfolders + the plans filed right here.
        @subfolders = ((@folder ? @folder_children[@folder.id] : @root_folders) || [])
          .sort_by { |f| f.name.downcase }
        level = filtered_plans(placed_directly_in(plans, @folder), nil)
          .order(updated_at: :desc, id: :desc)
        page_rows = level.limit(PER_PAGE + 1).to_a
        @level_has_next_page = page_rows.size > PER_PAGE
        @level_plans = page_rows.first(PER_PAGE)
        @plan_unread_counts = unread_counts_for(@level_plans)
        load_recently_updated if @folder.nil?
      end

      @breadcrumbs = folder_ancestry(@folder)
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
      # Old ?tab=history links: history is its own page now (the other
      # former tabs are same-page sections).
      return redirect_to history_plan_path(@plan) if params[:tab] == "history"
      # The viewer's own placement (if any) drives the toolbar's
      # Save/Saved state and the folder navigator's current-folder mark.
      @shelf_placements = @plan.placements
        .includes(:library, folder: { parent: :parent })
        .order(:created_at)
      @my_folders = current_user.library.folders.order(:name).to_a
      @threads = @plan.comment_threads.with_kept_comments.includes(:comments, :created_by_user).order(:created_at)
      @references = @plan.references.order(reference_type: :asc, created_at: :desc)
      @attachments = @plan.attachments_attachments.includes(:blob).order(created_at: :desc)
      # Order matters: compute the one-time "changed since you last looked"
      # highlights against the old last_seen_at, then advance it — so the
      # next visit renders clean.
      @changed_section_keys = changed_sections_since_last_visit
      PlanViewer.track(plan: @plan, user: current_user)
    end

    # A full page (reached from the header's clock icon), not a tab —
    # Backspace or the back link returns to the document.
    def history
      authorize!(@plan, :show?)
      @history_items = @plan.history_items
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

    # One direction of the header visibility toggle: share a private plan
    # with the whole org. The other direction is #hide — visibility is a
    # two-way switch (archive is the tool for "done with this").
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
      respond_to do |format|
        # The toggle fetches this: the header re-render carries the new
        # state flag, so the page repaints even when the ActionCable
        # broadcast can't reach this browser.
        format.turbo_stream { render turbo_stream: visibility_streams("Shared with everyone in the org.") }
        format.json { render json: { visibility: @plan.visibility } }
        format.html { redirect_to plan_path(@plan), notice: "Plan published — everyone can see it now." }
      end
    end

    # The other direction of the header eye: take a shared plan back to
    # Private. The URL keeps working (drafts are unlisted, not locked) —
    # this only withdraws the plan from discovery.
    def hide
      authorize!(@plan, :hide?)
      @plan.update!(visibility: "draft")
      broadcast_plan_update(@plan)
      Plans::LogEvent.call(
        plan: @plan,
        actor: current_user,
        event_type: "hidden",
        before: "published",
        after: "draft"
      )
      CoPlan::Analytics.track(
        "plan_hidden",
        user: current_user,
        plan_id: @plan.id,
        plan_type_id: @plan.plan_type_id,
        via: "web"
      )
      respond_to do |format|
        format.turbo_stream { render turbo_stream: visibility_streams("Private again — hidden from lists and search.") }
        format.json { render json: { visibility: @plan.visibility } }
        format.html { redirect_to plan_path(@plan), notice: "Plan is private again — hidden from lists and search." }
      end
    end

    # Archiving happens in place: the banner appears (with Restore — the
    # undo), the toolbar's menu loses its Archive entry, and a toast
    # confirms. No navigation, so the consequence is visible right where
    # the action happened.
    def archive
      authorize!(@plan, :archive?)
      @plan.update!(archived_at: Time.current)
      broadcast_plan_update(@plan)
      Plans::LogEvent.call(plan: @plan, actor: current_user, event_type: "archived")
      respond_to do |format|
        format.turbo_stream { render turbo_stream: archive_streams("Archived — hidden from lists, still readable at this URL.") }
        format.html { redirect_to plan_path(@plan), notice: "Plan archived. It's hidden from lists unless someone filters for archived plans." }
      end
    end

    def unarchive
      authorize!(@plan, :unarchive?)
      @plan.update!(archived_at: nil)
      broadcast_plan_update(@plan)
      Plans::LogEvent.call(plan: @plan, actor: current_user, event_type: "unarchived")
      respond_to do |format|
        format.turbo_stream { render turbo_stream: archive_streams("Plan restored.") }
        format.html { redirect_to plan_path(@plan), notice: "Plan restored." }
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

    # True when a non-folder filter narrows the workspace — the main pane
    # switches from the Drive-style level view to flat results.
    def filtered_view?
      @filter.present? || params[:tag].present? || params[:plan_type].present? ||
        @updated_window.present?
    end

    # The non-folder workspace filters. Folder scoping is separate
    # (placed_directly_in / in_folder_subtree) because the two view modes
    # apply it differently.
    def apply_workspace_filters(plans)
      plans = plans.where(plan_type_id: params[:plan_type]) if params[:plan_type].present?
      plans = plans.with_tag(params[:tag]) if params[:tag].present?
      plans = plans.where(updated_at: UPDATED_WINDOWS[@updated_window].ago..) if @updated_window
      plans
    end

    # Plans filed directly in `folder` in the viewer's library — or, at
    # root (nil), plans not filed anywhere. Root-level docs aren't a
    # special "Unfiled" category, they're just what sits at the top level,
    # like files loose in Drive's root.
    def placed_directly_in(plans, folder)
      if folder
        plans.joins(:placements)
          .where(coplan_plan_placements: { library_id: @library.id, folder_id: folder.id })
      else
        plans.where.not(id: @library.placements.select(:plan_id))
      end
    end

    # Everything under `folder` including subfolders — what filtered
    # results cover when you filter inside a folder. Folder ids come from
    # the viewer's own tree, so the placement join is already
    # library-scoped. nil folder = no narrowing.
    def in_folder_subtree(plans, folder)
      return plans unless folder

      plans.joins(:placements)
        .where(coplan_plan_placements: { folder_id: folder_subtree_ids(folder) })
    end

    # [root, ..., current] chain for the breadcrumb, walked over the
    # in-memory tree (cycle-guarded by the seen set).
    def folder_ancestry(folder)
      chain = []
      seen = Set.new
      node = folder
      while node && seen.add?(node.id)
        chain.unshift(node)
        node = @folders_by_id[node.parent_id]
      end
      chain
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

    # Sidebar data: folder tree counts, tag list, and type counts. Every
    # count answers "what would clicking this show?" — so each list is
    # computed with every *other* active filter applied (tag counts respect
    # the current folder/type/date, type counts respect tag/folder/date,
    # folder counts respect tag/type/date), INCLUDING the Hidden filter:
    # folder/tag/type links carry `filter` (WORKSPACE_LINK_PARAMS), so with
    # "Archived" active a folder count means "archived plans in here". All
    # from scoped_plans_base, so other users' private plans never leak
    # through counts (Plan.visible_to). Without a filter, archived plans
    # are opt-in and excluded (filtered_plans defaults to .active).
    def load_workspace_sidebar
      count_base = filtered_plans(scoped_plans_base, @filter)

      direct_counts = apply_workspace_filters(count_base)
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

      tag_base = count_base
      tag_base = tag_base.where(plan_type_id: params[:plan_type]) if params[:plan_type].present?
      tag_base = tag_base.where(updated_at: UPDATED_WINDOWS[@updated_window].ago..) if @updated_window
      tag_base = in_folder_subtree(tag_base, @folder)
      @top_tags = Tag
        .joins(:plan_tags)
        .where(coplan_plan_tags: { plan_id: tag_base.select("coplan_plans.id") })
        .group("coplan_tags.id", "coplan_tags.name")
        .order(Arel.sql("COUNT(*) DESC"), "coplan_tags.name ASC")
        .limit(8)
        .count
        .map { |(_id, name), count| [ name, count ] }

      type_base = count_base
      type_base = type_base.with_tag(params[:tag]) if params[:tag].present?
      type_base = type_base.where(updated_at: UPDATED_WINDOWS[@updated_window].ago..) if @updated_window
      type_base = in_folder_subtree(type_base, @folder)
      @type_counts = type_base.where.not(plan_type_id: nil).group(:plan_type_id).count

      # Updated windows count combinatorially too — every base includes all
      # the *other* active filters, never its own dimension.
      window_base = count_base
      window_base = window_base.where(plan_type_id: params[:plan_type]) if params[:plan_type].present?
      window_base = window_base.with_tag(params[:tag]) if params[:tag].present?
      window_base = in_folder_subtree(window_base, @folder)
      @updated_counts = UPDATED_WINDOWS.to_h do |window, duration|
        [ window, window_base.where(updated_at: duration.ago..).count ]
      end
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
      # The plan view hides resolved threads by default. Route each inbox row
      # through an unread notification so the destination marks it read and
      # deep-links to the exact thread, even when that thread is resolved.
      # This is deliberately bounded to ATTENTION_LIMIT indexed lookups.
      @attention_notification_ids = top_ids.index_with do |plan_id|
        current_user.notifications.unread.where(plan_id: plan_id).newest_first.pick(:id)
      end
      # Even an inbox routes through the discovery predicate — a stale
      # notification must not resurface an archived plan or another user's
      # unlisted draft.
      @attention_plans = Plan.visible_to(current_user).active.where(id: top_ids)
        .sort_by { |plan| -unread_by_plan.fetch(plan.id, 0) }
    end

    # Section keys (see Plans::ChangedSections) for content that changed
    # after the viewer's last visit. Empty on a first visit — highlighting
    # the whole document would say nothing.
    def changed_sections_since_last_visit
      seen_at = PlanViewer.where(plan: @plan, user: current_user).pick(:last_seen_at)
      return [] if seen_at.nil?

      current = @plan.current_plan_version
      return [] if current.nil? || current.created_at <= seen_at

      base = @plan.plan_versions.where(created_at: ..seen_at).order(revision: :desc).first
      return [] if base.nil?

      Plans::ChangedSections.call(
        old_content: base.content_markdown,
        new_content: current.content_markdown
      )
    end

    def set_plan
      @plan = Plan.find(params[:id])
    end

    def broadcast_plan_update(plan)
      Broadcaster.replace_to(plan, target: "plan-header", partial: "coplan/plans/header", locals: { plan: plan })
    end

    # Turbo Streams for a visibility change: re-render the header (the
    # byline's Private flag) and the toolbar (whose menu offers the
    # opposite direction now) in the acting browser, and confirm with a
    # toast.
    def visibility_streams(message)
      [
        turbo_stream.replace("plan-header", partial: "coplan/plans/header", locals: { plan: @plan }),
        turbo_stream.replace("plan-toolbar", partial: "coplan/plans/toolbar", locals: { plan: @plan }),
        toast_stream(message, "notice")
      ]
    end

    # Turbo Streams for archive/restore: the banner slot is the loud,
    # visible consequence (it appears with a Restore button — the undo),
    # the header's byline picks up/drops the Archived flag, and the
    # toolbar re-renders so its menu tracks the new state.
    def archive_streams(message)
      [
        turbo_stream.replace("plan-header", partial: "coplan/plans/header", locals: { plan: @plan }),
        turbo_stream.replace("plan-banner-slot", partial: "coplan/plans/banner", locals: { plan: @plan }),
        turbo_stream.replace("plan-toolbar", partial: "coplan/plans/toolbar", locals: { plan: @plan }),
        toast_stream(message, "notice")
      ]
    end
  end
end
