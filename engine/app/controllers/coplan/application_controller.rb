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
    helper CoPlan::ReferencesHelper

    # Skip host auth — CoPlan handles authentication internally via config.authenticate
    skip_before_action :authenticate_user!, raise: false

    before_action :authenticate_coplan_user!
    before_action :set_coplan_current
    after_action :set_agent_instructions_header

    helper_method :current_user, :signed_in?, :show_api_tokens?

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
      @current_coplan_user = CoPlan::Authentication.user_from_request(request)
      unless @current_coplan_user
        if agent_request?
          render plain: agent_redirect_instructions, content_type: "text/markdown", status: :unauthorized
        elsif CoPlan.configuration.sign_in_path
          redirect_to CoPlan.configuration.sign_in_path, alert: "Please sign in."
        else
          head :unauthorized
        end
      end
    end

    def set_coplan_current
      CoPlan::Current.user = current_user
    end

    def show_api_tokens?
      CoPlan.configuration.show_api_tokens?
    end

    def require_api_tokens_enabled
      head :not_found unless show_api_tokens?
    end

    def authorize!(record, action)
      policy_class = "CoPlan::#{record.class.name.demodulize}Policy".constantize
      policy = policy_class.new(current_user, record)
      unless policy.public_send(action)
        raise NotAuthorizedError
      end
    end

    def set_agent_instructions_header
      response.headers["X-Agent-Instructions"] = coplan.agent_instructions_path
    end

    def agent_request?
      ua = request.user_agent.to_s
      ua.present? && !ua.start_with?("Mozilla")
    end

    def agent_redirect_instructions
      base = request.base_url
      <<~MARKDOWN
        # CoPlan API

        You're accessing CoPlan's web UI, which requires browser authentication.

        To interact with CoPlan programmatically, use the API. Full instructions are at:

        #{base}#{coplan.agent_instructions_path}

        Read that document for authentication setup, endpoint reference, and usage examples.
      MARKDOWN
    end
  end
end
