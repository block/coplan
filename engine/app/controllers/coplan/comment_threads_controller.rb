module CoPlan
  class CommentThreadsController < ApplicationController
    include ActionView::RecordIdentifier

    before_action :set_plan
    before_action :set_thread, only: [:resolve, :accept, :discard, :reopen]

    def create
      authorize!(@plan, :show?)

      # Author's own comments start as "todo" (self-assigned work item);
      # non-author comments start as "pending" (awaiting author triage).
      initial_status = current_user.id == @plan.created_by_user_id ? "todo" : "pending"

      thread_params = params.expect(
        comment_thread: [ :anchor_text, :anchor_context, :anchor_occurrence,
                          :start_line, :end_line, :body_markdown ]
      )
      thread = @plan.comment_threads.new(
        plan_version: @plan.current_plan_version,
        anchor_text: thread_params[:anchor_text].presence,
        anchor_context: thread_params[:anchor_context].presence,
        anchor_occurrence: thread_params[:anchor_occurrence].presence&.to_i,
        start_line: thread_params[:start_line].presence,
        end_line: thread_params[:end_line].presence,
        created_by_user: current_user,
        status: initial_status
      )

      # Atomic: a thread without its first comment is an empty orphan whose
      # anchor still highlights.
      comment = nil
      ActiveRecord::Base.transaction do
        thread.save!
        comment = thread.comments.create!(
          author_type: "human",
          author_id: current_user.id,
          body_markdown: thread_params[:body_markdown]
        )
      end

      CreateNotificationsJob.perform_later(
        comment_thread_id: thread.id,
        actor_id: current_user.id,
        comment_id: comment.id,
        reason: "new_comment"
      )

      inline_streams = []
      if thread.anchored?
        locals = { thread: thread, plan: @plan }
        # The popover contains forms; the broadcast copy is rendered
        # requestless so other viewers never receive this request's session
        # authenticity tokens. The inline copy for the actor stays
        # request-scoped.
        Broadcaster.append_to(@plan, target: "plan-threads", partial: "coplan/comment_threads/thread_popover", locals: locals)
        html = render_to_string(partial: "coplan/comment_threads/thread_popover", locals: locals, formats: [:html])
        inline_streams << turbo_stream.append("plan-threads", html)
      end

      respond_with_stream_or_redirect("Comment added.", streams: inline_streams)
    end

    def resolve
      authorize!(@thread, :resolve?)
      @thread.resolve!(current_user)
      CreateNotificationsJob.perform_later(comment_thread_id: @thread.id, actor_id: current_user.id, reason: "status_change")
      stream = broadcast_thread_replace(@thread)
      respond_with_stream_or_redirect("Thread resolved.", streams: [stream])
    end

    def accept
      authorize!(@thread, :accept?)
      @thread.accept!(current_user)
      CreateNotificationsJob.perform_later(comment_thread_id: @thread.id, actor_id: current_user.id, reason: "status_change")
      stream = broadcast_thread_replace(@thread)
      respond_with_stream_or_redirect("Thread accepted.", streams: [stream])
    end

    def discard
      authorize!(@thread, :discard?)
      @thread.discard!(current_user)
      CreateNotificationsJob.perform_later(comment_thread_id: @thread.id, actor_id: current_user.id, reason: "status_change")
      stream = broadcast_thread_replace(@thread)
      respond_with_stream_or_redirect("Thread discarded.", streams: [stream])
    end

    def reopen
      authorize!(@thread, :reopen?)
      @thread.update!(status: "pending", resolved_by_user: nil)
      CreateNotificationsJob.perform_later(comment_thread_id: @thread.id, actor_id: current_user.id, reason: "status_change")
      stream = broadcast_thread_replace(@thread)
      respond_with_stream_or_redirect("Thread reopened.", streams: [stream])
    end

    private

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
        format.html { redirect_to plan_path(@plan), notice: message }
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
      html = render_to_string(partial: "coplan/comment_threads/thread_popover", locals: locals, formats: [:html])
      turbo_stream.replace(dom_id(thread), html)
    end
  end
end
