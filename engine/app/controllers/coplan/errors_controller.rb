module CoPlan
  # Public, but retain the viewer's normal navigation and theme when signed in.
  # Also used by the host exceptions app.
  class ErrorsController < ApplicationController
    skip_before_action :authenticate_coplan_user!, :set_coplan_current
    skip_after_action :restrict_embedded_frames, :track_page_view
    before_action :resolve_optional_coplan_user

    def not_found
      if request.format == Mime[:html]
        render "coplan/errors/not_found", layout: "coplan/application", status: :not_found
      else
        head :not_found
      end
    end

    private

    def resolve_optional_coplan_user
      @current_coplan_user = CoPlan::Authentication.user_from_request(request) if request.format == Mime[:html]
    end
  end
end
