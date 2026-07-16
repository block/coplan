module CoPlan
  class PlanPresenceChannel < ActionCable::Channel::Base
    def subscribed
      unless current_user
        reject
        return
      end

      @plan = Plan.find_by(id: params[:plan_id])
      policy = @plan && PlanPolicy.new(current_user, @plan)
      unless @plan && policy&.show?
        reject
        return
      end

      PlanViewer.track(plan: @plan, user: current_user)
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

      CoPlan::Authentication.user_from_request(connection.__send__(:request))
    end

    # Every viewer pings every 15s, and each ping used to re-render and
    # re-broadcast the full viewer list to every open tab even when nothing
    # changed. Skip the render + broadcast when the active-viewer set is
    # identical to what was last broadcast. Stale viewers still disappear
    # promptly: their dropping out changes the fingerprint, so the next ping
    # from any remaining viewer triggers a broadcast. With no cache store
    # (dev/test) the read returns nil and every ping broadcasts, preserving
    # the old behavior.
    def broadcast_viewers
      viewers = PlanViewer.active_viewers_for(@plan)

      fingerprint = viewers.map(&:id).join(",")
      cache_key = "coplan/presence-broadcast/#{@plan.id}"
      return if Rails.cache.read(cache_key) == fingerprint
      Rails.cache.write(cache_key, fingerprint, expires_in: 10.minutes)

      Broadcaster.replace_to(
        @plan,
        target: "plan-viewers",
        partial: "coplan/plans/viewers",
        locals: { viewers: viewers }
      )
    end
  end
end
