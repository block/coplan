module CoPlan
  # Home — the org-facing "what's happening" surface. A per-plan-per-day
  # activity feed over published work, plus the sitewide search in the nav
  # as the other discovery tool. Your own working list lives in your
  # library, at /<handle>; Home is everyone's.
  #
  # `?tag=` narrows it to one tag. Every cross-library list of plans lands
  # here: a list that spans libraries isn't a place inside one, which is
  # why it doesn't have a path in anybody's.
  class HomeController < ApplicationController
    def show
      @tag = params[:tag].presence
      @items = HomeFeed.build(tag: @tag)
      @items_by_date = @items.group_by(&:date)
    end
  end
end
