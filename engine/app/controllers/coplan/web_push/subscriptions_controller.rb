module CoPlan
  module WebPush
    class SubscriptionsController < ApplicationController
      before_action :require_web_push_configured

      # POST /web_push/subscription
      # Body: { subscription: { endpoint, keys: { p256dh, auth } } }
      def create
        sub_params = subscription_params
        record = WebPushSubscription.upsert_for(
          user: current_user,
          endpoint: sub_params[:endpoint],
          p256dh_key: sub_params.dig(:keys, :p256dh),
          auth_key: sub_params.dig(:keys, :auth),
          user_agent: request.user_agent&.truncate(255)
        )
        render json: { id: record.id, created_at: record.created_at }, status: :created
      end

      # GET /web_push/devices
      # Renders the device list inside its turbo-frame so the Settings page
      # can refresh just that section after enabling/disabling on this browser.
      def devices
        @web_push_subscriptions = current_user.web_push_subscriptions.order(created_at: :desc)
        render partial: "coplan/settings/settings/devices",
               locals: { web_push_subscriptions: @web_push_subscriptions }
      end

      # DELETE /web_push/subscription
      # Body: { subscription: { endpoint } }
      def destroy
        endpoint = subscription_params[:endpoint]
        digest = WebPushSubscription.digest_for(endpoint)
        # Scope to current_user so a leaked endpoint can't unsubscribe
        # someone else.
        deleted = current_user.web_push_subscriptions.where(endpoint_digest: digest).delete_all
        head deleted.positive? ? :no_content : :not_found
      end

      private

      def subscription_params
        params.require(:subscription).permit(:endpoint, keys: [:p256dh, :auth])
      end

      def require_web_push_configured
        head :service_unavailable unless CoPlan.configuration.web_push_configured?
      end
    end
  end
end
