module CoPlan
  class CommentsController < ApplicationController
    before_action :set_plan
    before_action :set_thread

    def create
      authorize!(@plan, :show?)

      comment = @thread.comments.create!(
        author_type: "human",
        author_id: current_user.id,
        body_markdown: params[:comment][:body_markdown]
      )

      CreateNotificationsJob.perform_later(
        comment_thread_id: @thread.id,
        actor_id: current_user.id,
        comment_id: comment.id,
        reason: "reply"
      )

      Broadcaster.append_to(
        @plan,
        target: ActionView::RecordIdentifier.dom_id(@thread, :comments),
        partial: "coplan/comments/comment",
        locals: { comment: comment }
      )

      # The broadcast above updates all clients (including the submitter) via WebSocket.
      # The empty turbo_stream response prevents Turbo from navigating (which causes scroll-to-top).
      respond_to do |format|
        format.turbo_stream { render turbo_stream: [] }
        format.html { redirect_to plan_path(@plan), notice: "Reply added." }
      end
    end

    def destroy
      comment = @thread.comments.find(params[:id])
      policy = CommentPolicy.new(current_user, comment)
      unless policy.delete?
        redirect_to plan_path(@plan), alert: "Not authorized to delete this comment." and return
      end

      Comments::SoftDelete.call(comment: comment, actor: current_user)

      if @thread.reload.empty?
        Broadcaster.remove_to(@plan, target: ActionView::RecordIdentifier.dom_id(@thread))
      else
        Broadcaster.replace_to(
          @plan,
          target: ActionView::RecordIdentifier.dom_id(comment),
          partial: "coplan/comments/comment",
          locals: { comment: comment }
        )
      end

      respond_to do |format|
        format.turbo_stream { render turbo_stream: [] }
        format.html { redirect_to plan_path(@plan), notice: "Comment deleted." }
      end
    end

    private

    def set_plan
      @plan = Plan.find(params[:plan_id])
    end

    def set_thread
      @thread = @plan.comment_threads.find(params[:comment_thread_id])
    end
  end
end
