module CoPlan
  module Reviews
    class Respond
      class Conflict < StandardError
        attr_reader :code

        def initialize(message, code: "review_version_changed")
          super(message)
          @code = code
        end
      end

      def self.call(request:, actor:, revision:, decision:, note: nil, api_token: nil, idempotency_key: nil)
        new(request:, actor:, revision:, decision:, note:, api_token:, idempotency_key:).call
      end

      def initialize(request:, actor:, revision:, decision:, note:, api_token:, idempotency_key:)
        @request, @actor, @revision, @decision, @note, @api_token = request, actor, revision, decision, note, api_token
        @idempotency_key = idempotency_key.presence
      end

      def call
        plan = @request.plan
        response = plan.with_lock do
          @request.reload
          response = ReviewResponse.new(review_request: @request, user: @actor, plan_version: plan.current_plan_version,
            decision: @decision, note: @note.to_s.strip.presence, actor_type: @api_token ? "local_agent" : "human",
            agent_name: @api_token && ApiToken.normalized_agent_name(@api_token.agent_name.presence || @api_token.name), api_token: @api_token)
          if @idempotency_key && (!@idempotency_key.is_a?(String) || !@idempotency_key.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i))
            response.errors.add(:base, "Idempotency key must be a UUID")
            raise ActiveRecord::RecordInvalid, response
          end
          @idempotency_key = @idempotency_key.downcase if @idempotency_key
          response.validate!
          # A stable response UUID separates transport retries from a new
          # review of the same version, including after another look is asked.
          if @idempotency_key
            existing = ReviewResponse.find_by(id: @idempotency_key)
            if existing
              fields = %w[review_request_id user_id decision note]
              next existing if existing.plan_version.revision.to_s == @revision.to_s && fields.all? { |field| existing.public_send(field) == response.public_send(field) }

              response.errors.add(:base, "This response was already recorded with different details. Start a new review decision to record your changes.")
              raise ActiveRecord::RecordInvalid, response
            end
            response.id = @idempotency_key
          end
          raise Conflict.new("This review request was withdrawn.", code: "review_request_withdrawn") if @request.status == "withdrawn"
          raise Conflict, "The plan has changed. Review the latest version before recording your response." unless @revision.to_s == plan.current_revision.to_s

          # Legacy clients cannot distinguish two identical intentions. Keep
          # the old response and preserve any newly re-requested pending task.
          existing = @request.review_responses.find_by(user: @actor, plan_version: plan.current_plan_version,
            decision: @decision, note: response.note, api_token_id: @api_token&.id)
          next existing if existing && !@idempotency_key

          if response.note.present?
            thread = plan.comment_threads.create!(plan_version: plan.current_plan_version, created_by_user: @actor)
            thread.comments.create!(body_markdown: response.note, author_type: response.actor_type,
              author_id: @actor.id, agent_name: response.agent_name, api_token: @api_token)
            response.comment_thread = thread
          end
          response.save!
          @new_response = true
          @request.update!(status: @decision)
          @request.notifications.unread.where(user: @actor).update_all(read_at: Time.current)
          unless @actor.id == plan.created_by_user_id
            Notification.create!(plan: plan, user_id: plan.created_by_user_id, review_request: @request,
              comment_thread: response.comment_thread, reason: "review_response")
          end
          response
        end
        if @new_response && response.comment_thread
          thread = response.comment_thread
          CreateNotificationsJob.perform_later(comment_thread_id: thread.id, actor_id: @actor.id,
            comment_id: thread.comments.first.id, reason: "new_comment", excluded_user_ids: [ plan.created_by_user_id ])
          Broadcaster.append_to(plan, target: "plan-threads", partial: "coplan/comment_threads/thread_popover", locals: { plan: plan, thread: thread })
          Broadcaster.replace_to(plan, target: "plan-general-comment-list", partial: "coplan/plans/general_comment_list",
            locals: { threads: plan.comment_threads.with_kept_comments.includes(:comments).order(:created_at) })
        end
        Changed.call(request: @request, event_type: "review.responded", actor_token_id: @api_token&.id,
          payload: { "decision" => response.decision, "revision" => response.plan_version.revision,
                     "actor_type" => response.actor_type, "agent_name" => response.agent_name,
                     "approval_meaning" => "Satisfied with this version; grants no execution authority or permissions." }) if @new_response
        response
      end
    end
  end
end
