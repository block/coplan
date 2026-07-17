module CoPlan
  # Renders the public landing page (mounted at "/welcome" and at "/").
  #
  # Behavior at "/" (root):
  # * Signed-in users who already have at least one plan are redirected to
  #   Home (the activity feed) — they know what CoPlan is and don't need the
  #   intro.
  # * Everyone else (signed-in users with no plans yet, or anyone hitting the
  #   page anonymously) sees the landing partial configured via
  #   `CoPlan.configuration.landing_page_partial`.
  #
  # Hosts can override the partial to inject deployment-specific copy (e.g.
  # coplan-square renders a Square-flavored landing that mentions
  # `sq agents skills add coplan`).
  class WelcomeController < ApplicationController
    # The landing page is intentionally public — it's the "what is this thing"
    # page that needs to work for first-time visitors. We replace the engine's
    # required-auth `before_action` with a softer version that resolves the
    # current user when present (so we can personalize CTAs and redirect
    # established users to /plans) but doesn't reject anonymous visitors.
    # Hosts that gate the whole app at the perimeter (BeyondCorp, OIDC) will
    # still enforce sign-in upstream.
    skip_before_action :authenticate_coplan_user!
    before_action :resolve_optional_coplan_user

    def show
      if signed_in? && current_user.created_plans.exists? && params[:force].blank?
        redirect_to home_path and return
      end

      @landing_partial = CoPlan.configuration.landing_page_partial
    end

    private

    def resolve_optional_coplan_user
      @current_coplan_user = CoPlan::Authentication.user_from_request(request)
    end
  end
end
