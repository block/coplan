module CoPlan
  class ServiceWorkersController < ApplicationController
    # Service worker registration runs from the browser without our session
    # cookie, and the SW URL needs to be public anyway.
    skip_before_action :authenticate_coplan_user!
    skip_before_action :verify_authenticity_token, raise: false

    SW_PATH     = CoPlan::Engine.root.join("app/javascript/coplan_service_worker.js")
    SW_TEMPLATE = SW_PATH.read.freeze
    ICON_TOKEN  = "__COPLAN_NOTIFICATION_ICON__"
    ICON_ASSET  = "coplan/coplan-logo-sm.png"

    def show
      # No Service-Worker-Allowed header on purpose: default scope is the
      # SW's own directory, which is the engine mount point. Push events
      # fire regardless of scope, so this doesn't limit notification reach.
      #
      # Render inline rather than send_file: the JS lives inside the gem,
      # so any reverse proxy that intercepts X-Sendfile (NGINX et al) won't
      # reach it. The file is small and cached in memory at boot, then we
      # substitute the digested icon URL per request.
      response.headers["Cache-Control"] = "no-cache"
      render plain: SW_TEMPLATE.gsub(ICON_TOKEN, view_context.asset_path(ICON_ASSET)),
             content_type: "application/javascript"
    end
  end
end
