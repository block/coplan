module CoPlan
  # Canonical URLs for the three browsable things. Views should link with
  # these rather than the id-based helpers, so what a reader copies out of
  # the address bar is already the readable form and no redirect is needed
  # to get there.
  module BrowseHelper
    def library_browse_path(library)
      browse_library_path(handle: library.handle)
    end

    def folder_browse_path(folder)
      browse_path(handle: folder.library.handle, slug_path: folder.slug_path)
    end

    # Falls back to the id form for a plan whose slug hasn't been
    # backfilled yet — the migration leaves them NULL and lets the app
    # fill them in on the next save, so both forms have to work meanwhile.
    def plan_browse_path(plan)
      path = plan.url_path
      return plan_path(plan) if path.blank?

      handle, _, rest = path.partition("/")
      browse_path(handle: handle, slug_path: rest)
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
