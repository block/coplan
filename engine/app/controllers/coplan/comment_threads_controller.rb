module CoPlan
  class CommentThreadsController < ApplicationController
    include ActionView::RecordIdentifier

    before_action :set_plan
    before_action :set_thread, only: [ :resolve, :reopen ]

    def create
      authorize!(@plan, :show?)

      thread_params = params.expect(
        comment_thread: [ :anchor_text, :anchor_context, :anchor_occurrence,
                          :start_line, :end_line, :body_markdown, :source_token ]
      )
      thread = @plan.comment_threads.new(
        plan_version: @plan.current_plan_version,
        anchor_text: thread_params[:anchor_text].presence,
        anchor_context: thread_params[:anchor_context].presence,
        anchor_occurrence: thread_params[:anchor_occurrence].presence&.to_i,
        source_token: thread_params[:source_token].presence,
        start_line: thread_params[:start_line].presence,
        end_line: thread_params[:end_line].presence,
        created_by_user: current_user
      )

      # Atomic: a thread without its first comment is an empty orphan whose
      # anchor still highlights.
      comment = nil
      begin
        ActiveRecord::Base.transaction do
          # Serialize source validation with plan edits. Reload the version
          # after taking the lock, including when this request waited on one.
          @plan.lock!
          thread.plan_version = @plan.current_plan_version
          thread.save!
          comment = thread.comments.create!(
            author_type: "human",
            author_id: current_user.id,
            body_markdown: thread_params[:body_markdown]
          )
        end
      rescue ActiveRecord::RecordInvalid => e
        # Most likely an anchor that doesn't resolve — a thread that would
        # render nowhere. Refused here rather than created invisible. The
        # selection form stays open (its reset checks for success) and
        # shows the message; the voice client retries on this status with
        # its viewport fallback.
        return render_comment_error(e.record.errors.full_messages.to_sentence)
      end

      CreateNotificationsJob.perform_later(
        comment_thread_id: thread.id,
        actor_id: current_user.id,
        comment_id: comment.id,
        reason: "new_comment"
      )

      locals = { thread: thread, plan: @plan }
      # The popover contains forms; broadcast HTML is rendered requestless
      # so it never carries the actor's session token to other viewers.
      Broadcaster.append_to(@plan, target: "plan-threads", partial: "coplan/comment_threads/thread_popover", locals: locals)
      html = render_to_string(partial: "coplan/comment_threads/thread_popover", locals: locals, formats: [ :html ])
      inline_streams = [ turbo_stream.append("plan-threads", html) ]
      inline_streams << general_comments_stream unless thread.anchored?

      respond_with_stream_or_redirect("Comment added.", streams: inline_streams)
    end

    def resolve
      authorize!(@thread, :resolve?)
      @thread.resolve!(current_user)
      CreateNotificationsJob.perform_later(comment_thread_id: @thread.id, actor_id: current_user.id, reason: "status_change")
      stream = broadcast_thread_replace(@thread)
      respond_with_stream_or_redirect("Thread resolved.", streams: [ stream, (@thread.anchored? ? nil : general_comments_stream) ].compact)
    end

    def reopen
      authorize!(@thread, :reopen?)
      @thread.reopen!(current_user)
      CreateNotificationsJob.perform_later(comment_thread_id: @thread.id, actor_id: current_user.id, reason: "status_change")
      stream = broadcast_thread_replace(@thread)
      respond_with_stream_or_redirect("Thread reopened.", streams: [ stream, (@thread.anchored? ? nil : general_comments_stream) ].compact)
    end

    private

    def render_comment_error(message)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [ turbo_stream.update("new-comment-form-error", message), turbo_stream.update("source-comment-error", message) ],
            status: :unprocessable_content
        end
        format.html { redirect_to helpers.plan_browse_path(@plan), alert: message }
      end
    end

    def set_plan
      @plan = Plan.find(params[:plan_id])
    end

    def set_thread
      @thread = @plan.comment_threads.find(params[:id])
    end

    # The actor's tab is updated inline by the HTTP response (no cable
    # round-trip); broadcasts handle every other viewer. Turbo stream
    # append/replace are idempotent when the broadcast echoes back to the
    # actor. An empty stream list still prevents Turbo from navigating
    # (which causes scroll-to-top).
    def respond_with_stream_or_redirect(message, streams: [])
      respond_to do |format|
        format.turbo_stream { render turbo_stream: streams }
        format.html { redirect_to helpers.plan_browse_path(@plan), notice: message }
      end
    end

    # Replaces a thread in place (status changed) for other viewers and
    # returns the inline stream for the actor's own response. The broadcast
    # renders requestless (the popover contains forms — request-rendered
    # HTML would leak this session's authenticity tokens to every viewer);
    # only the actor's inline copy is request-scoped.
    def broadcast_thread_replace(thread)
      locals = { thread: thread, plan: @plan }
      Broadcaster.replace_to(@plan, target: dom_id(thread), partial: "coplan/comment_threads/thread_popover", locals: locals)
      html = render_to_string(partial: "coplan/comment_threads/thread_popover", locals: locals, formats: [ :html ])
      turbo_stream.replace(dom_id(thread), html)
    end

    def general_comments_stream
      locals = { threads: @plan.comment_threads.with_kept_comments.includes(:comments).order(:created_at) }
      Broadcaster.replace_to(@plan, target: "plan-general-comments", partial: "coplan/plans/general_comments", locals: locals)
      html = render_to_string(partial: "coplan/plans/general_comments", locals: locals, formats: [ :html ])
      turbo_stream.replace("plan-general-comments", html)
    end
  end
end
