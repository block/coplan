module CoPlan
  module Urls
    # Turns a browsable URL into the thing it points at.
    #
    #   /orders                            → library
    #   /orders/liveorder                  → folder
    #   /orders/liveorder/cart-roadmap     → plan
    #
    # Resolution walks one segment at a time — handle, then folder slug
    # within the previous folder, then a plan slug in whatever folder we
    # landed in. Nothing stores a joined path, which is why renaming a
    # folder can't invalidate anything below it.
    #
    # The last segment is ambiguous by nature: it might be a subfolder or
    # it might be a plan. Folders win. A folder has children hanging off
    # it, so mistaking a folder for a plan would break a whole subtree,
    # while the reverse breaks one document — and the plan can still be
    # reached with its disambiguating suffix.
    class Resolve
      # `redirect_to_path` is set when the request arrived at a stale but
      # recognizable path: the caller should 301 rather than render.
      Result = Struct.new(:library, :folder, :plan, :redirect_to_path, keyword_init: true) do
        def found? = library.present?

        # What the URL actually addressed, for the caller to authorize.
        def target = plan || folder || library
      end

      NOT_FOUND = Result.new.freeze

      def self.call(handle:, slug_path: nil)
        new(handle:, slug_path:).call
      end

      def initialize(handle:, slug_path: nil)
        @handle = handle.to_s
        @segments = slug_path.to_s.split("/").map { |segment| segment.strip.downcase }.reject(&:blank?)
      end

      def call
        library = Library.find_by_handle(@handle)
        return resolve_stale_handle if library.nil?
        return Result.new(library: library) if @segments.empty?

        walk(library)
      end

      private

      # Descends as far as the folder tree goes, then asks whether the
      # leftover segment names a plan.
      def walk(library)
        folder = nil
        @segments.each_with_index do |segment, index|
          child = library.folders.find_by(parent_id: folder&.id, slug: segment)
          if child
            folder = child
            next
          end

          # Not a folder — only the final segment may be a plan.
          return resolve_stale_path(library) unless index == @segments.length - 1

          plan = find_plan(library, folder, segment)
          return plan ? Result.new(library:, folder:, plan:) : resolve_stale_path(library)
        end

        Result.new(library:, folder:)
      end

      # Plans are addressed by slug within the folder they're filed in
      # (or filed nowhere, at the library root). The optional `~suffix`
      # disambiguates two plans whose titles slugify the same way.
      def find_plan(library, folder, segment)
        # rpartition puts the whole string in its *last* slot when the
        # separator is absent, so the no-suffix case is split explicitly.
        slug, suffix = if segment.include?("~")
          head, _, tail = segment.rpartition("~")
          [ head, tail ]
        else
          [ segment, nil ]
        end

        scope = if folder
          Plan.where(id: library.placements.where(folder_id: folder.id).select(:plan_id))
        else
          # No folder segment: the plan sits at the library root, which
          # means it has no placement row to find it by.
          library.unfiled_plans
        end

        scope.find_by(slug: slug, slug_suffix: suffix.presence)
      end

      # A path we can't walk might still be a path we used to know.
      def resolve_stale_path(library)
        alias_redirect(File.join(library.handle, *@segments)) || NOT_FOUND
      end

      def resolve_stale_handle
        alias_redirect(File.join(*[ @handle, *@segments ].compact_blank)) || NOT_FOUND
      end

      def alias_redirect(path)
        rewritten = UrlAlias.rewrite(path)
        return nil if rewritten.nil? || rewritten == path

        Result.new(library: Library.find_by_handle(rewritten.split("/").first),
          redirect_to_path: rewritten)
      end
    end
  end
end
