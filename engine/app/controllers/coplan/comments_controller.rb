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

      target = ActionView::RecordIdentifier.dom_id(@thread, :comments)
      html = render_to_string(partial: "coplan/comments/comment", locals: { comment: comment }, formats: [:html])

      Broadcaster.append_to(@plan, target: target, html: html)

      # The author's tab gets the append inline in the HTTP response — no
      # cable round-trip between submit and seeing the comment. The broadcast
      # above still updates every other viewer; Turbo removes same-id children
      # before appending, so the author's copy isn't duplicated when the
      # broadcast echoes back.
      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.append(target, html) }
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
        target = ActionView::RecordIdentifier.dom_id(@thread)
        Broadcaster.remove_to(@plan, target: target)
        inline_stream = turbo_stream.remove(target)
      else
        target = ActionView::RecordIdentifier.dom_id(comment)
        html = render_to_string(partial: "coplan/comments/comment", locals: { comment: comment }, formats: [:html])
        Broadcaster.replace_to(@plan, target: target, html: html)
        inline_stream = turbo_stream.replace(target, html)
      end

      # Inline response updates the actor immediately; the broadcast handles
      # other viewers (remove/replace are idempotent on echo).
      respond_to do |format|
        format.turbo_stream { render turbo_stream: inline_stream }
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
