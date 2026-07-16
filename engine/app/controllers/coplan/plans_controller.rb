module CoPlan
  class PlansController < ApplicationController
    before_action :set_plan, only: [:show, :edit, :update, :update_status, :toggle_checkbox, :history, :edit_content, :update_content, :preview]

    PER_PAGE = 20

    SCOPES = %w[mine all].freeze
    DEFAULT_SCOPE = "mine".freeze

    def index
      @scope = SCOPES.include?(params[:scope]) ? params[:scope] : DEFAULT_SCOPE

      plans = Plan.includes(:plan_type, :tags, :created_by_user, :current_plan_version)

      if @scope == "mine"
        plans = plans.where(created_by_user: current_user)
      else
        plans = plans.where.not(status: "brainstorm")
          .or(Plan.where(created_by_user: current_user))
      end

      plans = plans.where(status: params[:status]) if params[:status].present?
      plans = plans.where(plan_type_id: params[:plan_type]) if params[:plan_type].present?
      plans = plans.with_tag(params[:tag]) if params[:tag].present?

      # Group "My Plans" by status (active → brainstorm) when not already filtered
      # to a single status. The "All" view stays sorted by recency.
      @grouped_by_status = @scope == "mine" && params[:status].blank?
      plans = @grouped_by_status ? plans.prioritized_by_status : plans.order(updated_at: :desc, id: :desc)

      @page = (params[:page] || 1).to_i
      @plans = plans.limit(PER_PAGE + 1).offset((@page - 1) * PER_PAGE)
      @has_next_page = @plans.size > PER_PAGE
      @plans = @plans.first(PER_PAGE)

      @plan_unread_counts = current_user.notifications.unread
        .where(plan_id: @plans.map(&:id))
        .group(:plan_id)
        .count

      if turbo_frame_request?
        render partial: "coplan/plans/plan_page",
          locals: {
            plans: @plans,
            plan_unread_counts: @plan_unread_counts,
            page: @page,
            has_next_page: @has_next_page,
            grouped_by_status: @grouped_by_status,
            previous_status: params[:prev_status].presence,
          },
          layout: false
      else
        @plan_types = PlanType.order(:name)
        @show_onboarding_banner = CoPlan.configuration.onboarding_banner.present? &&
          !current_user.created_plans.exists?
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
