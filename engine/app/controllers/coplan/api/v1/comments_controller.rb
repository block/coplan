module CoPlan
  module Api
    module V1
      class CommentsController < BaseController
        before_action :set_plan
        before_action :authorize_plan_access!

        def create
          thread = @plan.comment_threads.new(
            plan_version: @plan.current_plan_version,
            anchor_text: params[:anchor_text].presence,
            anchor_occurrence: params[:anchor_occurrence]&.to_i,
            start_line: params[:start_line].presence,
            end_line: params[:end_line].presence,
            created_by_user: current_user
          )

          thread.save!

          comment = thread.comments.create!(
            author_type: api_author_type,
            author_id: api_actor_id,
            body_markdown: params[:body_markdown],
            agent_name: params[:agent_name]
          )

          broadcast_new_thread(thread)

          render json: {
            thread_id: thread.id,
            comment_id: comment.id,
            status: thread.status,
            created_at: thread.created_at
          }, status: :created

        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
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
          broadcast_thread_update(thread)

          render json: { thread_id: thread.id, status: thread.status }
        end

        def dismiss
          thread = @plan.comment_threads.find_by(id: params[:id])
          unless thread
            render json: { error: "Comment thread not found" }, status: :not_found
            return
          end

          policy = CommentThreadPolicy.new(current_user, thread)
          unless policy.dismiss?
            render json: { error: "Not authorized" }, status: :forbidden
            return
          end

          thread.dismiss!(current_user)
          broadcast_thread_update(thread)

          render json: { thread_id: thread.id, status: thread.status }
        end

        def reply
          thread = @plan.comment_threads.find_by(id: params[:id])
          unless thread
            render json: { error: "Comment thread not found" }, status: :not_found
            return
          end

          comment = thread.comments.create!(
            author_type: api_author_type,
            author_id: api_actor_id,
            body_markdown: params[:body_markdown],
            agent_name: params[:agent_name]
          )

          broadcast_new_comment(thread, comment)

          render json: {
            comment_id: comment.id,
            thread_id: thread.id,
            created_at: comment.created_at
          }, status: :created

        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def broadcast_new_thread(thread)
          Broadcaster.prepend_to(
            @plan,
            target: "comment-threads",
            partial: "coplan/comment_threads/thread",
            locals: { thread: thread, plan: @plan }
          )
        end

        def broadcast_thread_update(thread)
          Broadcaster.replace_to(
            @plan,
            target: ActionView::RecordIdentifier.dom_id(thread),
            partial: "coplan/comment_threads/thread",
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
