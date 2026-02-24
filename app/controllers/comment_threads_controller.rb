class CommentThreadsController < ApplicationController
  include ActionView::RecordIdentifier

  before_action :scope_to_organization
  before_action :set_plan
  before_action :set_thread, only: [:resolve, :accept, :dismiss, :reopen]

  def create
    authorize!(@plan, :show?)

    thread = @plan.comment_threads.new(
      organization: @organization,
      plan_version: @plan.current_plan_version,
      anchor_text: params[:comment_thread][:anchor_text].presence,
      anchor_context: params[:comment_thread][:anchor_context].presence,
      start_line: params[:comment_thread][:start_line].presence,
      end_line: params[:comment_thread][:end_line].presence,
      created_by_user: current_user
    )

    thread.save!

    comment = thread.comments.create!(
      organization: @organization,
      author_type: "human",
      author_id: current_user.id,
      body_markdown: params[:comment_thread][:body_markdown]
    )

    broadcast_new_thread(thread)
    broadcast_tab_counts

    respond_with_stream_or_redirect("Comment added.")
  end

  def resolve
    authorize!(@thread, :resolve?)
    @thread.resolve!(current_user)
    broadcast_thread_move(@thread, from: "comment-threads", to: "resolved-comment-threads")
    respond_with_stream_or_redirect("Thread resolved.")
  end

  def accept
    authorize!(@thread, :accept?)
    @thread.accept!(current_user)
    broadcast_thread_move(@thread, from: "comment-threads", to: "resolved-comment-threads")
    respond_with_stream_or_redirect("Thread accepted.")
  end

  def dismiss
    authorize!(@thread, :dismiss?)
    @thread.dismiss!(current_user)
    broadcast_thread_move(@thread, from: "comment-threads", to: "resolved-comment-threads")
    respond_with_stream_or_redirect("Thread dismissed.")
  end

  def reopen
    authorize!(@thread, :reopen?)
    @thread.update!(status: "open", resolved_by_user: nil)
    # Out-of-date threads stay in the archived list even when reopened,
    # since the active scope excludes out_of_date rows.
    if @thread.out_of_date?
      broadcast_thread_replace(@thread)
    else
      broadcast_thread_move(@thread, from: "resolved-comment-threads", to: "comment-threads")
    end
    respond_with_stream_or_redirect("Thread reopened.")
  end

  private

  def set_plan
    @plan = @organization.plans.find(params[:plan_id])
  end

  def set_thread
    @thread = @plan.comment_threads.find(params[:id])
  end

  def broadcast_new_thread(thread)
    Turbo::StreamsChannel.broadcast_prepend_to(
      @plan,
      target: "comment-threads",
      partial: "comment_threads/thread",
      locals: { thread: thread, plan: @plan }
    )
  end

  # Broadcasts update all clients (including the submitter) via WebSocket.
  # The empty turbo_stream response prevents Turbo from navigating (which causes scroll-to-top).
  def respond_with_stream_or_redirect(message)
    respond_to do |format|
      format.turbo_stream { render turbo_stream: [] }
      format.html { redirect_to plan_path(@plan), notice: message }
    end
  end

  # Replaces a thread in place (status changed but stays in the same list).
  def broadcast_thread_replace(thread)
    Turbo::StreamsChannel.broadcast_replace_to(
      @plan,
      target: dom_id(thread),
      partial: "comment_threads/thread",
      locals: { thread: thread, plan: @plan }
    )
    broadcast_tab_counts
  end

  # Moves a thread between Open/Resolved lists and updates tab counts.
  def broadcast_thread_move(thread, from:, to:)
    Turbo::StreamsChannel.broadcast_remove_to(@plan, target: dom_id(thread))
    Turbo::StreamsChannel.broadcast_append_to(
      @plan,
      target: to,
      partial: "comment_threads/thread",
      locals: { thread: thread, plan: @plan }
    )
    broadcast_tab_counts
  end

  def broadcast_tab_counts
    threads = @plan.comment_threads
    open_count = threads.active.count
    resolved_count = threads.archived.count

    Turbo::StreamsChannel.broadcast_update_to(
      @plan,
      target: "open-thread-count",
      html: open_count > 0 ? open_count.to_s : ""
    )
    Turbo::StreamsChannel.broadcast_update_to(
      @plan,
      target: "resolved-thread-count",
      html: resolved_count > 0 ? resolved_count.to_s : ""
    )

    # Toggle empty-state placeholders
    Turbo::StreamsChannel.broadcast_replace_to(
      @plan,
      target: "open-threads-empty",
      html: %(<p class="text-sm text-muted" id="open-threads-empty" #{'style="display: none;"' if open_count > 0}>No open comments.</p>)
    )
    Turbo::StreamsChannel.broadcast_replace_to(
      @plan,
      target: "resolved-threads-empty",
      html: %(<p class="text-sm text-muted" id="resolved-threads-empty" #{'style="display: none;"' if resolved_count > 0}>No resolved comments.</p>)
    )
  end
end
