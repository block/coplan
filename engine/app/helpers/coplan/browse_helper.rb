module CoPlan
  # Canonical URLs for the three browsable things. Views should link with
  # these rather than the id-based helpers, so what a reader copies out of
  # the address bar is already the readable form and no redirect is needed
  # to get there.
  module BrowseHelper
    def library_browse_path(library, **options)
      browse_library_path(handle: library.handle, **options)
    end

    # "Back to your own work" — where anything that needs somewhere to
    # land goes when it has no place of its own to return to. This is the
    # app's home base, and it's an address like any other.
    def own_library_browse_path(user, **options)
      library_browse_path(user.library, **options)
    end

    def folder_browse_path(folder, **options)
      browse_path(handle: folder.library.handle, slug_path: folder.slug_path, **options)
    end

    # A plan has exactly one address, so there is no id form to fall back
    # to: `slug` is NOT NULL and every plan sits in exactly one library
    # (see BackfillPlanSlugs), which makes `url_path` total.
    #
    # Extra options (`thread:`, `anchor:`) ride along, so deep links keep
    # working without knowing anything about the shape of the path.
    #
    # Built from the view's own route helpers rather than delegating to
    # Urls::Canonical: a host that mounts the engine somewhere other than
    # "/" gets the mount prefix from the request, and route helpers called
    # outside a request have no way to know about it.
    def plan_browse_path(plan, **options)
      handle, slug_path = Urls::Canonical.split(plan.url_path)
      browse_path(handle: handle, slug_path: slug_path, **options)
    end

    # Absolute form, for rel=canonical and anything that leaves the app.
    def plan_browse_url(plan)
      handle, slug_path = Urls::Canonical.split(plan.url_path)
      browse_url(handle: handle, slug_path: slug_path)
    end

    # The document's own pages, addressed under the document. Same split as
    # above, so they stay correct through a retitle or a move.
    def plan_edit_browse_path(plan, **options)
      handle, slug_path = Urls::Canonical.split(plan.url_path)
      browse_edit_path(handle: handle, slug_path: slug_path, **options)
    end

    def plan_history_browse_path(plan, **options)
      handle, slug_path = Urls::Canonical.split(plan.url_path)
      browse_history_path(handle: handle, slug_path: slug_path, **options)
    end

    def plan_version_browse_path(plan, version, **options)
      handle, slug_path = Urls::Canonical.split(plan.url_path)
      browse_version_path(handle: handle, slug_path: slug_path,
        revision: version.revision, **options)
    end

    def plan_version_diff_browse_path(plan, version, **options)
      handle, slug_path = Urls::Canonical.split(plan.url_path)
      browse_version_diff_path(handle: handle, slug_path: slug_path,
        revision: version.revision, **options)
    end

    # Level-view link for either kind of row, so folder and plan lists
    # don't each need to know which helper to reach for.
    def browse_path_for(record)
      case record
      when CoPlan::Folder then folder_browse_path(record)
      when CoPlan::Library then library_browse_path(record)
      else plan_browse_path(record)
      end
    end
  end
end
