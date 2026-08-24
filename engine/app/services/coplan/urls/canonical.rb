module CoPlan
  module Urls
    # Builds the readable address of a document with no request in hand —
    # background jobs, push payloads, anything with no view context to
    # borrow route helpers from. A caller that *has* a request should go
    # through `CoPlan::BrowseHelper` instead, which is mount-aware.
    #
    # Paths only, and mount-prefix-free: engine route helpers called outside
    # a request can't know where the host mounted the engine. That's the
    # same limitation every other non-request caller here lives with (see
    # SlackNotificationJob, Api::V1::BaseController) and it costs nothing
    # while the engine is mounted at "/".
    #
    # The absolute form needs a host, which only a request knows, so
    # `browse_url` stays in the helper.
    module Canonical
      # `/<handle>/<folders>/<slug>` — the plan's one and only address.
      # There's no id form to fall back to: `slug` is NOT NULL and a plan
      # lives in exactly one library, so this is total.
      def self.plan_path(plan, **options)
        handle, slug_path = split(plan.url_path)
        CoPlan::Engine.routes.url_helpers
          .browse_path(handle: handle, slug_path: slug_path, **options)
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
