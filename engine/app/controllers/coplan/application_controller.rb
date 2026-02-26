module CoPlan
  class ApplicationController < ::ApplicationController
    layout "coplan/application"

    # CoPlan.underscore produces "co_plan", but our views/templates use "coplan/"
    def self.controller_path
      super.sub(/\Aco_plan\//, "coplan/")
    end

    helper CoPlan::ApplicationHelper
    helper CoPlan::MarkdownHelper
    helper CoPlan::CommentsHelper

    before_action :authenticate_coplan_user!
    before_action :set_coplan_current

    helper_method :current_user, :signed_in?

    class NotAuthorizedError < StandardError; end

    rescue_from NotAuthorizedError do
      head :not_found
    end

    private

    def current_user
      @current_coplan_user
    end

    def signed_in?
      current_user.present?
    end

    def authenticate_coplan_user!
      callback = CoPlan.configuration.authenticate
      unless callback
        raise "CoPlan.configure { |c| c.authenticate = ->(request) { ... } } is required"
      end

      attrs = callback.call(request)
      unless attrs && attrs[:external_id].present?
        head :unauthorized
        return
      end

      @current_coplan_user = CoPlan::User.find_or_initialize_by(external_id: attrs[:external_id].to_s)
      @current_coplan_user.assign_attributes(attrs.slice(:name, :admin, :metadata).compact)
      @current_coplan_user.save! if @current_coplan_user.new_record? || @current_coplan_user.changed?
    end

    def set_coplan_current
      CoPlan::Current.user = current_user
    end

    def authorize!(record, action)
      policy_class = "CoPlan::#{record.class.name.demodulize}Policy".constantize
      policy = policy_class.new(current_user, record)
      unless policy.public_send(action)
        raise NotAuthorizedError
      end
    end
  end
end
