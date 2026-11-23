module Coplan
  module Admin
    module Authentication
      private

      def current_coplan_admin_user
        @current_coplan_admin_user ||= Coplan::Authentication.user_from_request(request)
      end

      def authenticate_coplan_admin!
        user = current_coplan_admin_user
        unless user
          return redirect_to(Coplan.configuration.sign_in_path) if Coplan.configuration.sign_in_path

          return head :unauthorized
        end

        return head :forbidden unless user.admin?

        Coplan::Current.user = user
      end
    end

    # Hosts opt in from their ActiveAdmin initializer. Their app/admin files
    # then share this namespace, so a host can add pages without copying any
    # of the engine's registrations.
    def self.install!(active_admin, path: "_/admin")
      active_admin.load_paths << Coplan::Engine.root.join("app/admin").to_s
      active_admin.default_namespace = :admin
      active_admin.authentication_method = :authenticate_coplan_admin!
      active_admin.current_user_method = :current_coplan_admin_user
      active_admin.logout_link_path = false
      active_admin.comments = false
      ActiveAdmin.importmap.pin "@hotwired/stimulus", to: "stimulus.min.js"
      ActiveAdmin.importmap.pin "coplan/admin_comments", to: "coplan/admin_comments.js"
      ActiveAdmin.importmap.pin "controllers/coplan/admin_comment_deletion_controller", to: "controllers/coplan/admin_comment_deletion_controller.js"
      active_admin.namespace :admin do |namespace|
        namespace.route_options = { path: path }
        namespace.site_title = "Coplan Admin"
      end

      ActiveSupport.on_load(:action_controller_base) { include Coplan::Admin::Authentication }
    end
  end
end
