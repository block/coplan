module CoPlan
  class CommentReactionsController < ApplicationController
    before_action :set_comment

    # PATCH with `kind` and `reacted` (true or false). Sending the desired
    # state rather than "toggle" keeps repeated or retried requests from
    # flipping the reaction back.
    def update
      authorize!(@plan, :show?)

      kind = params[:kind].to_s
      reacted = { "true" => true, "false" => false }[params[:reacted].to_s]
      unless CommentReaction::KINDS.key?(kind) && !reacted.nil?
        render plain: "Unknown reaction.", status: :unprocessable_content
        return
      end
      if @comment.deleted?
        render plain: "You can't react to a deleted comment.", status: :unprocessable_content
        return
      end

      # The change and its version move together, so a page never sees one
      # without the other. Bumping first locks the comment's row, so changes
      # to one comment's reactions take turns.
      Comment.transaction do
        @comment.bump_reactions_version!
        if reacted
          add_reaction(kind)
        else
          @comment.reactions.where(user: current_user, kind: kind).delete_all
        end
      end
      @comment.reload
      CommentReaction.preload_for(@comment)
      target = ActionView::RecordIdentifier.dom_id(@comment, :reactions)
      locals = { comment: @comment }
      Broadcaster.replace_to(@plan, target: target, partial: "coplan/comments/reactions", locals: locals)
      html = render_to_string(partial: "coplan/comments/reactions", locals: locals, formats: [ :html ])

      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.replace(target, html) }
        format.html { redirect_to helpers.plan_browse_path(@plan) }
      end
    end

    private

    # A concurrent request can add the same reaction between the lookup and
    # the insert; depending on timing that surfaces as the uniqueness
    # validation or as the unique index. The savepoint keeps the enclosing
    # transaction usable after the index rejects the insert.
    def add_reaction(kind)
      return if @comment.reactions.exists?(user: current_user, kind: kind)

      CommentReaction.transaction(requires_new: true) { @comment.reactions.create!(user: current_user, kind: kind) }
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      raise unless @comment.reactions.exists?(user: current_user, kind: kind)
    end

    def set_comment
      @plan = Plan.find(params[:plan_id])
      thread = @plan.comment_threads.find(params[:comment_thread_id])
      @comment = thread.comments.find(params[:comment_id])
    end
  end
end
