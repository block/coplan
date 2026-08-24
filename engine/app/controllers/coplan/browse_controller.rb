module CoPlan
  # Serves the browsable URLs — the canonical address of everything in a
  # library, and of the person whose library it is.
  #
  #   /sam                             Sam, and Sam's library
  #   /sam/liveorder                   a folder
  #   /sam/liveorder/cart-roadmap      a document
  #   /sam/liveorder/cart-roadmap/edit the document's editor
  #
  # Every prefix is a real page, so trimming a segment off any URL walks
  # you up the tree. One action serves all of them because they are one
  # thing — a place in a library, and the pages belonging to what's there
  # — and which of them a path names isn't knowable until the segments are
  # resolved against the database.
  #
  # Inherits PlansController to reuse the workspace index and the document
  # views wholesale rather than duplicating (or prematurely extracting)
  # ~250 lines of interdependent loading. The action is named `browse`, not
  # `show`, so the inherited `before_action :set_plan, only: [:show, ...]`
  # doesn't fire on a path that has no plan id in it.
  class BrowseController < PlansController
    # A document's sub-pages: the `page` a route supplied, mapped to the
    # inherited action that renders it and the template it renders.
    # Anything not in here is a plain document page.
    PAGES = {
      "edit" => { action: :edit_content, template: "coplan/plans/edit_content" },
      "history" => { action: :history, template: "coplan/plans/history" },
      "version" => { action: :version, template: "coplan/plan_versions/show" },
      # A bare fragment: the history page loads it into a turbo-frame.
      "version_diff" => { action: :version_diff, template: "coplan/plan_versions/diff", layout: false }
    }.freeze

    def browse
      result = resolve

      # A tail only names an action when it hangs off a document. On
      # `/sam/notes/history`, where "notes" is a folder, "history" is a
      # document slug (or nothing) — so put the path back together and
      # resolve it as a place.
      if page && !result.plan
        params.delete(:page)
        result = resolve(slug_path: [ params[:slug_path], *page_tail ].compact_blank.join("/"))
      end
      return head :not_found unless result.found?

      # A stale-but-recognizable path: 301 so the address bar, and
      # everything copied out of it, converges on the current URL.
      if result.redirect_to_path.present?
        return redirect_to path_to_url(result.redirect_to_path), status: :moved_permanently
      end

      result.plan ? render_plan(result.plan) : render_library(result.library, result.folder)
    end

    private

    def resolve(slug_path: params[:slug_path])
      Urls::Resolve.call(handle: params[:handle], slug_path: slug_path)
    end

    def page
      PAGES[params[:page]]
    end

    # The segments a sub-page route consumed, so a path that turns out not
    # to name one can be reassembled.
    def page_tail
      case params[:page]
      when "edit" then [ "edit" ]
      when "history" then [ "history" ]
      when "version" then [ "history", params[:revision] ]
      when "version_diff" then [ "history", params[:revision], "diff" ]
      else []
      end
    end

    def render_plan(plan)
      @plan = plan
      authorize!(@plan, :show?)
      target = page || { action: :show, template: "coplan/plans/show" }
      send(target[:action])
      render target[:template], layout: target.fetch(:layout, true) unless performed?
    end

    # Every library renders the same page. What you can do to what's in it
    # is a question for the buttons — Library#writable_by?, surfaced to the
    # views as @can_write — not a question of which view to render. A
    # separate read-only page was the thing that made someone else's
    # library feel like a different, lesser app: no filters, no folder
    # counts, no "since you last looked".
    #
    # The resolved folder is handed to `index` directly: a folder is a
    # place with an address, so it never travels as a query param.
    def render_library(library, folder)
      authorize!(library, :show?)
      @library = library
      @folder = folder
      index
      render "coplan/plans/index" unless performed?
    end

    def path_to_url(path)
      handle, _, rest = path.partition("/")
      rest.present? ? browse_path(handle: handle, slug_path: rest) : browse_library_path(handle: handle)
    end
  end
end
