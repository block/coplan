module CoPlan
  # Serves the browsable URLs — the canonical address of everything in a
  # library, and of the person whose library it is.
  #
  #   /sam                             Sam, and Sam's library
  #   /sam/liveorder                   a folder
  #   /sam/liveorder/cart-roadmap      a document
  #
  # Every prefix is a real page, so trimming a segment off any URL walks
  # you up the tree. One action serves all three because they are one
  # thing — a place in a library — and which of the three a path names
  # isn't knowable until the segments are resolved against the database.
  #
  # Inherits PlansController to reuse the workspace index and the document
  # view wholesale rather than duplicating (or prematurely extracting)
  # ~250 lines of interdependent loading. The action is named `browse`, not
  # `show`, so the inherited `before_action :set_plan, only: [:show, ...]`
  # doesn't fire on a path that has no plan id in it.
  class BrowseController < PlansController
    def browse
      result = Urls::Resolve.call(handle: params[:handle], slug_path: params[:slug_path])
      return head :not_found unless result.found?

      # A stale-but-recognizable path: 301 so the address bar, and
      # everything copied out of it, converges on the current URL.
      if result.redirect_to_path.present?
        return redirect_to path_to_url(result.redirect_to_path), status: :moved_permanently
      end

      result.plan ? render_plan(result.plan) : render_library(result.library, result.folder)
    end

    private

    def render_plan(plan)
      @plan = plan
      authorize!(@plan, :show?)
      show
      render "coplan/plans/show" unless performed?
    end

    # Every library renders the same page. What you can do to what's in it
    # is a question for the buttons — Library#writable_by?, surfaced to the
    # views as @can_write — not a question of which view to render. A
    # separate read-only page was the thing that made someone else's
    # library feel like a different, lesser app: no filters, no folder
    # counts, no "since you last looked".
    #
    # `index` reads the folder from params, so the resolved folder is
    # handed over the same way the legacy ?folder=<id> form supplied it.
    def render_library(library, folder)
      authorize!(library, :show?)
      @library = library
      params[:folder] = folder&.id
      index
      render "coplan/plans/index" unless performed?
    end

    def path_to_url(path)
      handle, _, rest = path.partition("/")
      rest.present? ? browse_path(handle: handle, slug_path: rest) : browse_library_path(handle: handle)
    end
  end
end
