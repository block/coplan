module BrowsePathHelpers
  # The readable addresses, for specs that want the page itself rather
  # than a hop. Everything in the app has exactly one address now, so
  # these have no id-form fallback: `plan_path` still exists and 301s
  # onto `plan_page_path`.

  # A plan's address — `/<handle>/<folders>/<slug>`.
  def plan_page_path(plan, **options)
    handle, rest = split_plan_path(plan)
    coplan_routes.browse_path(handle: handle, slug_path: rest, **options)
  end

  # Open the document's inline editor at its canonical address.
  def plan_edit_page_path(plan, **options)
    plan_page_path(plan, edit: 1, **options)
  end

  # The old URL is kept only as a redirect for existing bookmarks.
  def plan_legacy_edit_page_path(plan, **options)
    handle, rest = split_plan_path(plan)
    coplan_routes.browse_edit_path(handle: handle, slug_path: rest, **options)
  end

  def plan_history_page_path(plan, **options)
    handle, rest = split_plan_path(plan)
    coplan_routes.browse_history_path(handle: handle, slug_path: rest, **options)
  end

  def plan_version_page_path(plan, version, **options)
    handle, rest = split_plan_path(plan)
    coplan_routes.browse_version_path(handle: handle, slug_path: rest,
      revision: version.revision, **options)
  end

  def plan_version_diff_page_path(plan, version, **options)
    handle, rest = split_plan_path(plan)
    coplan_routes.browse_version_diff_path(handle: handle, slug_path: rest,
      revision: version.revision, **options)
  end

  # A library's page, which is also the workspace of whoever owns it —
  # what `plans_path` used to point at, now that it has an address.
  # Takes a user or a library.
  def library_page_path(owner, **params)
    library = owner.is_a?(Coplan::Library) ? owner : owner.library
    coplan_routes.browse_library_path(handle: library.handle, **params)
  end

  def folder_page_path(folder, **params)
    coplan_routes.browse_path(handle: folder.library.handle,
      slug_path: folder.slug_path, **params)
  end

  private

  def coplan_routes
    Coplan::Engine.routes.url_helpers
  end

  def split_plan_path(plan)
    handle, _, rest = plan.url_path.partition("/")
    [ handle, rest ]
  end
end

RSpec.configure do |config|
  config.include BrowsePathHelpers
end
