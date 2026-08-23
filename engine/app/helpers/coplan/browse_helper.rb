module CoPlan
  # Canonical URLs for the three browsable things. Views should link with
  # these rather than the id-based helpers, so what a reader copies out of
  # the address bar is already the readable form and no redirect is needed
  # to get there.
  module BrowseHelper
    def library_browse_path(library, **options)
      browse_library_path(handle: library.handle, **options)
    end

    def folder_browse_path(folder, **options)
      browse_path(handle: folder.library.handle, slug_path: folder.slug_path, **options)
    end

    # Falls back to the id form for a plan whose slug hasn't been
    # backfilled yet — the migration leaves them NULL and lets the app
    # fill them in on the next save, so both forms have to work meanwhile.
    #
    # Extra options (`thread:`, `anchor:`) ride along either way, so
    # deep links don't have to know which form they got.
    #
    # Built from the view's own route helpers rather than delegating to
    # Urls::Canonical: a host that mounts the engine somewhere other than
    # "/" gets the mount prefix from the request, and route helpers called
    # outside a request have no way to know about it.
    def plan_browse_path(plan, **options)
      handle, slug_path = Urls::Canonical.split(plan.url_path)
      return plan_path(plan, **options) if slug_path.blank?

      browse_path(handle: handle, slug_path: slug_path, **options)
    end

    # Absolute form, for rel=canonical. Returns nil rather than falling
    # back: a canonical tag pointing at the id form would be claiming the
    # ugly URL is the real one.
    def plan_browse_url(plan)
      handle, slug_path = Urls::Canonical.split(plan.url_path)
      slug_path && browse_url(handle: handle, slug_path: slug_path)
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
