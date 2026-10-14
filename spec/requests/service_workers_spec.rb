require "rails_helper"

RSpec.describe "Service Worker", type: :request do
  describe "GET /coplan_service_worker.js" do
    it "serves the service worker JS without authentication" do
      get service_worker_path
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/javascript")
      expect(response.headers["Cache-Control"]).to include("no-cache")
      expect(response.body).to include("self.addEventListener(\"push\"")
      expect(response.body).to include(ActionController::Base.helpers.asset_path("coplan/coplan-logo.png"))
      expect(response.body).not_to include("__COPLAN_NOTIFICATION_ICON__")
    end
  end
end
