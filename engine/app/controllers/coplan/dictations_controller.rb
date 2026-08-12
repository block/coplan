module CoPlan
  # "What did I just say, and what was I looking at?" — asked by the voice
  # control after transcribing, before it posts the comment.
  #
  # Deliberately a separate request from creating the comment: the model
  # call is the slow, failure-prone part, and the comment must not depend
  # on it. The client sends what it heard and what was on screen, uses the
  # answer if it arrives in time, and posts the raw transcript if not.
  class DictationsController < ApplicationController
    before_action :set_plan

    def create
      authorize!(@plan, :show?)

      result = Comments::InterpretDictation.call(
        excerpt: excerpt,
        transcript: params[:transcript].to_s
      )

      # Which copy of the span it is stays the client's job — it can see
      # the rendered document and where in it the person was looking,
      # which is how selection-anchored comments already work.
      render json: { body: result.body, anchor_text: result.anchor_text }
    end

    private

    def set_plan
      @plan = Plan.find(params[:plan_id])
    end

    # Only what the person could actually see. Narrower is better on
    # every axis: the model picks the passage more accurately, has the
    # right context for repairing mis-transcribed jargon, the call is
    # cheaper, and less of the document leaves the building. Falls back
    # to the whole plan when the client can't say what was on screen.
    def excerpt
      visible = params[:excerpt].to_s
      return @plan.current_content.to_s if visible.strip.empty?

      visible.truncate(8_000, omission: "")
    end
  end
end
