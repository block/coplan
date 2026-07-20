module CoPlan
  # Home — the org-facing "what's happening" surface. A per-plan-per-day
  # activity feed over published work, plus the sitewide search in the nav
  # as the other discovery tool. Your own working list lives in the
  # Workspace (/plans); Home is everyone's.
  class HomeController < ApplicationController
    def show
      @items = HomeFeed.build
      @items_by_date = @items.group_by(&:date)
    end
  end
end
