module CoPlan
  class LlmsController < ApplicationController
    skip_before_action :authenticate_coplan_user!

    def show
      render layout: false, content_type: "text/markdown", formats: [:text]
    end
  end
end
