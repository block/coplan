module CoPlan
  module Admin
    module Authentication
      private

      def current_coplan_admin_user
        @current_coplan_admin_user ||= CoPlan::Authentication.user_from_request(request)
      end

      def authenticate_coplan_admin!
        user = current_coplan_admin_user
        unless user
          return redirect_to(CoPlan.configuration.sign_in_path) if CoPlan.configuration.sign_in_path

          return head :unauthorized
        end

        return head :forbidden unless user.admin?

        CoPlan::Current.user = user
      end
    end

    # Hosts opt in from their ActiveAdmin initializer. Their app/admin files
    # then share this namespace, so a host can add pages without copying any
    # of the engine's registrations.
    def self.install!(active_admin, path: "_/admin")
      active_admin.load_paths << CoPlan::Engine.root.join("app/admin").to_s
      active_admin.default_namespace = :admin
      active_admin.authentication_method = :authenticate_coplan_admin!
      active_admin.current_user_method = :current_coplan_admin_user
      active_admin.logout_link_path = false
      active_admin.comments = false
      active_admin.namespace :admin do |namespace|
        namespace.route_options = { path: path }
        namespace.site_title = "CoPlan Admin"
      end

      ActiveSupport.on_load(:action_controller_base) { include CoPlan::Admin::Authentication }
    end
  end
end
