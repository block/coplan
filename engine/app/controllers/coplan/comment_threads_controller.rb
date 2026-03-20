module CoPlan
  class CommentThreadsController < ApplicationController
    include ActionView::RecordIdentifier

    before_action :set_plan
    before_action :set_thread, only: [:resolve, :accept, :dismiss, :reopen]

    def create
      authorize!(@plan, :show?)

      thread = @plan.comment_threads.new(
        plan_version: @plan.current_plan_version,
        anchor_text: params[:comment_thread][:anchor_text].presence,
        anchor_context: params[:comment_thread][:anchor_context].presence,
        anchor_occurrence: params[:comment_thread][:anchor_occurrence].presence&.to_i,
        start_line: params[:comment_thread][:start_line].presence,
        end_line: params[:comment_thread][:end_line].presence,
        created_by_user: current_user
      )

      thread.save!

      comment = thread.comments.create!(
        author_type: "human",
        author_id: current_user.id,
        body_markdown: params[:comment_thread][:body_markdown]
      )

      respond_with_stream_or_redirect("Comment added.")
    end

    def resolve
      authorize!(@thread, :resolve?)
      @thread.resolve!(current_user)
      broadcast_thread_replace(@thread)
      respond_with_stream_or_redirect("Thread resolved.")
    end

    def accept
      authorize!(@thread, :accept?)
      @thread.accept!(current_user)
      broadcast_thread_replace(@thread)
      respond_with_stream_or_redirect("Thread accepted.")
    end

    def dismiss
      authorize!(@thread, :dismiss?)
      @thread.dismiss!(current_user)
      broadcast_thread_replace(@thread)
      respond_with_stream_or_redirect("Thread dismissed.")
    end

    def reopen
      authorize!(@thread, :reopen?)
      @thread.update!(status: "open", resolved_by_user: nil)
      broadcast_thread_replace(@thread)
      respond_with_stream_or_redirect("Thread reopened.")
    end

    private

    def set_plan
      @plan = Plan.find(params[:plan_id])
    end

    def set_thread
      @thread = @plan.comment_threads.find(params[:id])
    end

    # Broadcasts update all clients (including the submitter) via WebSocket.
    # The empty turbo_stream response prevents Turbo from navigating (which causes scroll-to-top).
    def respond_with_stream_or_redirect(message)
      respond_to do |format|
        format.turbo_stream { render turbo_stream: [] }
        format.html { redirect_to plan_path(@plan), notice: message }
      end
    end

    # Replaces a thread in place (status changed).
    def broadcast_thread_replace(thread)
      Broadcaster.replace_to(
        @plan,
        target: dom_id(thread),
        partial: "coplan/comment_threads/thread",
        locals: { thread: thread, plan: @plan }
      )
    end
  end
end
