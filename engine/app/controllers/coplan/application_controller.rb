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

    before_action :set_coplan_current

    private

    def set_coplan_current
      CoPlan::Current.user = current_user
    end

    def authorize!(record, action)
      policy_class = "CoPlan::#{record.class.name.demodulize}Policy".constantize
      policy = policy_class.new(current_user, record)
      unless policy.public_send(action)
        raise ::ApplicationController::NotAuthorizedError
      end
    end
  end
end
