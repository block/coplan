module CoPlan
  class PlanVersionsController < ApplicationController
    before_action :set_plan
    before_action :set_version, only: [:show]

    def index
      authorize!(@plan, :show?)
      @versions = @plan.plan_versions.order(revision: :desc)
    end

    def show
      authorize!(@plan, :show?)
      @previous_version = @plan.plan_versions.find_by(revision: @version.revision - 1)
      if @previous_version
        @diff = Diffy::Diff.new(@previous_version.content_markdown, @version.content_markdown, include_plus_and_minus_in_html: true, context: 3)
      end
    end

    private

    def set_plan
      @plan = Plan.find(params[:plan_id])
    end

    def set_version
      @version = @plan.plan_versions.find(params[:id])
    end
  end
end
