module CoPlan
  # "Which words was I talking about?" — asked by the voice control just
  # before it posts a dictated comment, so the comment lands on the
  # sentence the person meant rather than the section they were near.
  #
  # Deliberately a separate request from creating the comment: the model
  # call is the slow, failure-prone part, and the comment must not depend
  # on it. The client sends what it can see, uses the answer if it gets
  # one in time, and posts with its own fallback anchor if it doesn't.
  class AnchorSuggestionsController < ApplicationController
    before_action :set_plan

    def create
      authorize!(@plan, :show?)

      suggestion = Comments::SuggestAnchor.call(
        excerpt: excerpt,
        transcript: params[:transcript].to_s
      )

      # Which copy of the span it is stays the client's job — it can see
      # the rendered document and where in it the person was looking,
      # which is exactly how selection-anchored comments already work.
      render json: { anchor_text: suggestion }
    end

    private

    def set_plan
      @plan = Plan.find(params[:plan_id])
    end

    # Only what the person could actually see. Narrower is better on
    # every axis: the model picks more accurately, the call is cheaper,
    # and less of the document leaves the building. Falls back to the
    # whole plan when the client can't say what was on screen.
    def excerpt
      visible = params[:excerpt].to_s
      return @plan.current_content.to_s if visible.strip.empty?

      visible.truncate(8_000, omission: "")
    end
  end
end
