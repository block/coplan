module CoPlan
  module Urls
    # Builds the readable address of a document from anywhere — views,
    # controllers, background jobs, push payloads. `CoPlan::BrowseHelper`
    # delegates here; so does anything that has no view context to borrow
    # route helpers from.
    #
    # Paths only. The absolute form needs a host, which only a request
    # knows, so `browse_url` stays in the helper.
    module Canonical
      # `/l/<handle>/<folders>/<slug>`, or the id form for a plan whose
      # slug hasn't been backfilled yet. Both have to work while slugs
      # fill in, and `/plans/<uuid>` 301s here once one exists.
      def self.plan_path(plan, **options)
        routes = CoPlan::Engine.routes.url_helpers
        handle, slug_path = split(plan.url_path)
        return routes.plan_path(plan, **options) if slug_path.blank?

        routes.browse_path(handle: handle, slug_path: slug_path, **options)
      end

      # Splits "handle/rest/of/path" into its two route segments. A path
      # with no rest names a library, not a document.
      def self.split(path)
        return [ nil, nil ] if path.blank?

        handle, _, rest = path.partition("/")
        [ handle, rest.presence ]
      end
    end
  end
end
