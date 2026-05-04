module CoPlan
  class PlanPresenceChannel < ActionCable::Channel::Base
    def subscribed
      @current_user = resolve_current_user
      unless @current_user
        reject
        return
      end

      @plan = Plan.find_by(id: params[:plan_id])
      policy = @plan && PlanPolicy.new(@current_user, @plan)
      unless @plan && policy&.show?
        reject
        return
      end

      PlanViewer.track(plan: @plan, user: @current_user)
      broadcast_viewers
    end

    def unsubscribed
      return unless @plan

      PlanViewer.expire(plan: @plan, user: current_user)
      broadcast_viewers
    end

    def ping
      return unless @plan

      PlanViewer.track(plan: @plan, user: current_user)
      broadcast_viewers
    end

    private

    def current_user
      @current_user ||= resolve_current_user
    end

    def resolve_current_user
      return connection.current_user if connection.respond_to?(:current_user) && connection.current_user

      CoPlan::Authentication.user_from_request(connection.request)
    end

    def broadcast_viewers
      viewers = PlanViewer.active_viewers_for(@plan)
      Broadcaster.replace_to(
        @plan,
        target: "plan-viewers",
        partial: "coplan/plans/viewers",
        locals: { viewers: viewers }
      )
    end
  end
end
