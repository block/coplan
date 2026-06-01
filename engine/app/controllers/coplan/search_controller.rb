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
  # Anonymous access is allowed — signed-out users see only published plans
  # (this matches `Plan.search`'s visibility filter). Recent searches are
  # only persisted for signed-in users.
  class SearchController < ApplicationController
    skip_before_action :authenticate_coplan_user!
    before_action :resolve_optional_coplan_user

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

      if @query.present? && current_user
        SearchQuery.log!(user: current_user, query: @query)
      end

      @recent_queries = current_user ? SearchQuery.recent_for(current_user).pluck(:query) : []

      if params[:frame] == "results"
        render partial: "coplan/search/results", layout: false, locals: {
          query: @query,
          results: @results,
          recent_queries: @recent_queries
        }
      end
    end

    private

    def resolve_optional_coplan_user
      @current_coplan_user = CoPlan::Authentication.user_from_request(request)
    end
  end
end
