module CoPlan
  module Api
    module V1
      class CommentsController < BaseController
        before_action :set_plan
        before_action :authorize_plan_access!

        # GET /api/v1/plans/:plan_id/comments/:id — a single thread with its
        # comments, so an agent reacting to one inbox event doesn't have to
        # refetch every thread on the plan.
        def show
          thread = @plan.comment_threads.includes(:comments, :created_by_user).find_by(id: params[:id])
          unless thread
            render json: { error: "Comment thread not found" }, status: :not_found
            return
          end

          render json: thread_json(thread)
        end

        def create
          # Same initial-status rule as the web flow: the plan author's own
          # comments start as "todo" (self-assigned), everyone else's as
          # "pending" (awaiting author triage).
          initial_status = current_user&.id == @plan.created_by_user_id ? "todo" : "pending"

          thread = @plan.comment_threads.new(
            plan_version: @plan.current_plan_version,
            anchor_text: params[:anchor_text].presence,
            anchor_occurrence: params[:anchor_occurrence]&.to_i,
            start_line: params[:start_line].presence,
            end_line: params[:end_line].presence,
            created_by_user: current_user,
            status: initial_status
          )

          # Atomic, matching the web flow: a thread whose first comment
          # fails validation (e.g. missing agent_name) must not survive as
          # an empty orphan with a live anchor highlight.
          comment = nil
          ActiveRecord::Base.transaction do
            thread.save!
            comment = thread.comments.create!(
              author_type: api_author_type,
              author_id: current_user&.id,
              body_markdown: params[:body_markdown],
              agent_name: resolved_agent_name
            )
          end

          reason = comment.agent? ? "agent_response" : "new_comment"
          CreateNotificationsJob.perform_later(
            comment_thread_id: thread.id,
            actor_id: api_actor_id,
            comment_id: comment.id,
            reason: reason
          )

          broadcast_new_thread(thread)

          render json: {
            id: thread.id,
            thread_id: thread.id,
            comment_id: comment.id,
            status: thread.status,
            created_at: thread.created_at
          }, status: :created

        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_content
        end

        def resolve
          thread = @plan.comment_threads.find_by(id: params[:id])
          unless thread
            render json: { error: "Comment thread not found" }, status: :not_found
            return
          end

          policy = CommentThreadPolicy.new(current_user, thread)
          unless policy.resolve?
            render json: { error: "Not authorized" }, status: :forbidden
            return
          end

          thread.resolve!(current_user)
          CreateNotificationsJob.perform_later(comment_thread_id: thread.id, actor_id: current_user.id, reason: "status_change")
          broadcast_thread_update(thread)

          render json: { thread_id: thread.id, status: thread.status }
        end

        def discard
          thread = @plan.comment_threads.find_by(id: params[:id])
          unless thread
            render json: { error: "Comment thread not found" }, status: :not_found
            return
          end

          policy = CommentThreadPolicy.new(current_user, thread)
          unless policy.discard?
            render json: { error: "Not authorized" }, status: :forbidden
            return
          end

          thread.discard!(current_user)
          CreateNotificationsJob.perform_later(comment_thread_id: thread.id, actor_id: current_user.id, reason: "status_change")
          broadcast_thread_update(thread)

          render json: { thread_id: thread.id, status: thread.status }
        end

        def destroy
          # Scope the lookup to this plan's comments so an ID from another
          # plan returns 404 rather than being acted on. (The policy also
          # gates on authorship, but scoping here keeps the resource
          # boundary explicit and the 404 correct.)
          comment = @plan.comments.find_by(id: params[:id])

          unless comment
            render json: { error: "Comment not found" }, status: :not_found
            return
          end

          policy = CommentPolicy.new(current_user, comment)
          unless policy.delete?
            render json: { error: "Not authorized" }, status: :forbidden
            return
          end

          Comments::SoftDelete.call(comment: comment, actor: current_user)

          thread = comment.comment_thread
          if thread.reload.empty?
            Broadcaster.remove_to(@plan, target: ActionView::RecordIdentifier.dom_id(thread))
          else
            Broadcaster.replace_to(
              @plan,
              target: ActionView::RecordIdentifier.dom_id(comment),
              partial: "coplan/comments/comment",
              locals: { comment: comment }
            )
          end

          render json: { comment_id: comment.id, deleted_at: comment.deleted_at }
        end

        def reply
          thread = @plan.comment_threads.find_by(id: params[:id])
          unless thread
            render json: { error: "Comment thread not found" }, status: :not_found
            return
          end

          comment = thread.comments.create!(
            author_type: api_author_type,
            author_id: current_user&.id,
            body_markdown: params[:body_markdown],
            agent_name: resolved_agent_name
          )

          reason = comment.agent? ? "agent_response" : "reply"
          CreateNotificationsJob.perform_later(
            comment_thread_id: thread.id,
            actor_id: api_actor_id,
            comment_id: comment.id,
            reason: reason
          )

          broadcast_new_comment(thread, comment)

          # `id` is the created resource, matching every other create in
          # this API; comment_id/thread_id stay for existing callers.
          render json: {
            id: comment.id,
            comment_id: comment.id,
            thread_id: thread.id,
            created_at: comment.created_at
          }, status: :created

        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_content
        end

        private

        # Token-authored comments are agent comments, and agents shouldn't
        # have to repeat their name on every write: they already declared
        # it when claiming the agent session, or on the token itself. An
        # explicit param still wins, so one agent can post under a
        # different persona.
        #
        # Truncated rather than rejected — a name a few characters over
        # the display limit is not a reason to lose someone's comment.
        def resolved_agent_name
          name = params[:agent_name].presence || default_agent_name
          name&.truncate(Comment::AGENT_NAME_LIMIT, omission: "…")
        end

        def default_agent_name
          return nil unless @api_token

          AgentSession.find_by(plan_id: @plan.id, api_token_id: @api_token.id)&.agent_name.presence ||
            @api_token.agent_name.presence ||
            @api_token.name
        end

        # Mirrors PlansController#thread_json so GET .../comments/:id returns
        # the same shape as the list/snapshot endpoints.
        def thread_json(thread)
          {
            id: thread.id,
            status: thread.status,
            anchor_text: thread.anchor_text,
            anchor_context: thread.anchor_context_with_highlight,
            anchor_valid: thread.anchor_valid?,
            start_line: thread.start_line,
            end_line: thread.end_line,
            out_of_date: thread.out_of_date,
            created_by: thread.created_by_user&.name,
            created_at: thread.created_at,
            comments: thread.comments.sort_by(&:created_at).map { |c|
              {
                id: c.id,
                author_type: c.author_type,
                author_id: c.author_id,
                agent_name: c.agent_name,
                body_markdown: c.body_markdown,
                created_at: c.created_at
              }
            }
          }
        end

        def broadcast_new_thread(thread)
          Broadcaster.append_to(
            @plan,
            target: "plan-threads",
            partial: "coplan/comment_threads/thread_popover",
            locals: { thread: thread, plan: @plan }
          )
        end

        def broadcast_thread_update(thread)
          Broadcaster.replace_to(
            @plan,
            target: ActionView::RecordIdentifier.dom_id(thread),
            partial: "coplan/comment_threads/thread_popover",
            locals: { thread: thread, plan: @plan }
          )
        end

        def broadcast_new_comment(thread, comment)
          Broadcaster.append_to(
            @plan,
            target: ActionView::RecordIdentifier.dom_id(thread, :comments),
            partial: "coplan/comments/comment",
            locals: { comment: comment }
          )
        end
      end
    end
  end
end
