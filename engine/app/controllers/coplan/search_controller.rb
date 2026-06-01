module CoPlan
  # Sitewide search. Accessible from anywhere via the `/` keyboard shortcut or
  # the header search bar.
  #
  # The endpoint serves two shapes:
  # * `format=html` (default) — full search results page (used for direct
  #   navigation, e.g. a bookmarked /search?q=foo).
  # * `frame=results` query param — just the results list partial, used by
  #   the modal's Turbo Frame to swap in results as the user types.
  #
  # Sign-in required. Anonymous visitors get the usual redirect to the
  # sign-in page — we don't want search leaking plan titles or content to
  # unauthenticated callers.
  class SearchController < ApplicationController
    MAX_RESULTS = 20

    def index
      @query = params[:q].to_s.strip
      @results = if @query.present?
        Plan.search(@query, user: current_user)
          .includes(:created_by_user, :tags)
          .limit(MAX_RESULTS)
          .to_a
      else
        []
      end

      # Only persist explicit navigations as recent searches — not every
      # typeahead `frame=results` request fired on each keystroke. Otherwise
      # typing "roadmap" would log r, ro, roa, … and evict actual recents.
      if @query.present? && params[:frame] != "results"
        SearchQuery.log!(user: current_user, query: @query)
      end

      @recent_queries = SearchQuery.recent_for(current_user).pluck(:query)

      if params[:frame] == "results"
        render partial: "coplan/search/results", layout: false, locals: {
          query: @query,
          results: @results,
          recent_queries: @recent_queries
        }
      end
    end
  end
end
