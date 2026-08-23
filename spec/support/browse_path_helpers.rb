module BrowsePathHelpers
  # A plan's readable address — `/<handle>/<folders>/<slug>` — which is
  # the document's URL now. `plan_path` still works and 301s here, so a
  # spec that wants the page itself asks for this and skips the hop.
  #
  # Falls back to `plan_path` for a plan with no slug yet, matching what
  # the app does: both forms have to work while slugs backfill.
  def plan_page_path(plan, **options)
    helpers = CoPlan::Engine.routes.url_helpers
    path = plan.url_path
    return helpers.plan_path(plan, **options) if path.blank?

    handle, _, rest = path.partition("/")
    helpers.browse_path(handle: handle, slug_path: rest, **options)
  end
end

RSpec.configure do |config|
  config.include BrowsePathHelpers
end
