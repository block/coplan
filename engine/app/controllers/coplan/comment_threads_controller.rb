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

      thread = @plan.comment_threads.new(
        plan_version: @plan.current_plan_version,
        anchor_text: params[:comment_thread][:anchor_text].presence,
        anchor_context: params[:comment_thread][:anchor_context].presence,
        anchor_occurrence: params[:comment_thread][:anchor_occurrence].presence&.to_i,
        start_line: params[:comment_thread][:start_line].presence,
        end_line: params[:comment_thread][:end_line].presence,
        created_by_user: current_user,
        status: initial_status
      )

      thread.save!

      comment = thread.comments.create!(
        author_type: "human",
        author_id: current_user.id,
        body_markdown: params[:comment_thread][:body_markdown]
      )

      CreateNotificationsJob.perform_later(
        comment_thread_id: thread.id,
        actor_id: current_user.id,
        comment_id: comment.id,
        reason: "new_comment"
      )

      inline_streams = []
      if thread.anchored?
        html = render_to_string(partial: "coplan/comment_threads/thread_popover", locals: { thread: thread, plan: @plan }, formats: [:html])
        Broadcaster.append_to(@plan, target: "plan-threads", html: html)
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
    # returns the inline stream for the actor's own response.
    def broadcast_thread_replace(thread)
      html = render_to_string(partial: "coplan/comment_threads/thread_popover", locals: { thread: thread, plan: @plan }, formats: [:html])
      Broadcaster.replace_to(@plan, target: dom_id(thread), html: html)
      turbo_stream.replace(dom_id(thread), html)
    end
  end
end
