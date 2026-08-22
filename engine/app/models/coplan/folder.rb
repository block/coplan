module CoPlan
  # A shelf in a library. Folders form a small hierarchy (max MAX_DEPTH
  # levels) inside exactly one library, and hold plans via placements —
  # a plan sits in at most one folder per library, but can be shelved in
  # many libraries at once. Tags remain the cross-cutting labels; folders
  # answer "where did this library's owner file this plan?".
  #
  # Folders belong to their library, never directly to a user — write
  # access is the library's call (Library#writable_by?), which is what
  # lets a future team library reuse all of this unchanged.
  class Folder < ApplicationRecord
    include BroadcastsLibraryChanges

    MAX_DEPTH = 3

    # "/" is reserved as the path separator for folder_path lookups
    # (e.g. "Team EBT/Q3"), so it can't appear in a folder name.
    NAME_FORMAT = %r{\A[^/]+\z}

    belongs_to :library, class_name: "CoPlan::Library", inverse_of: :folders
    belongs_to :parent, class_name: "CoPlan::Folder", optional: true, inverse_of: :children
    has_many :children, class_name: "CoPlan::Folder", foreign_key: :parent_id,
      inverse_of: :parent, dependent: nil
    belongs_to :created_by_user, class_name: "CoPlan::User", optional: true
    has_many :placements, class_name: "CoPlan::PlanPlacement", inverse_of: :folder, dependent: nil
    has_many :plans, class_name: "CoPlan::Plan", through: :placements

    # Strip on the way in so every write path gets clean names, not just
    # find_or_create_by_path!.
    normalizes :name, with: ->(name) { name.strip }

    # The folder's URL segment, derived from its name. Nothing downstream
    # stores it — a plan knows only its own slug — so renaming a folder
    # updates this one row and no plan row at all.
    #
    # On both callbacks deliberately: before_validation so the uniqueness
    # check sees the slug, before_save so a `save(validate: false)` still
    # produces a NOT NULL-satisfying row. The method is idempotent.
    before_validation :assign_slug
    before_save :assign_slug
    # A rename or a move leaves behind one prefix alias, which covers
    # every plan and subfolder underneath — O(renames), not O(documents).
    before_save :stash_previous_url_path
    after_save :record_url_alias
    # The folder tree and every count beside it are on screen for anyone
    # browsing this library — a new shelf, a rename, a move or a deletion
    # all change what they are looking at.
    after_commit :broadcast_folder_change

    validates :name, presence: true,
      uniqueness: { scope: [ :library_id, :parent_id ], case_sensitive: false },
      format: { with: NAME_FORMAT, message: "cannot contain \"/\"" },
      length: { maximum: 100 }
    # Siblings can share neither a name nor a slug: "Team EBT" and
    # "Team-EBT" are distinct names claiming the same URL segment.
    # Folders never take a disambiguating suffix the way plans do — a
    # folder's segment appears in every URL beneath it, so it stays clean
    # and the second folder is asked for a different name instead.
    validates :slug, presence: true,
      uniqueness: { scope: [ :library_id, :parent_id ], case_sensitive: false,
                    message: "is already taken by a folder here" }
    # What belongs in this folder, in one line — read by agents (via the
    # library overview API) to organize by meaning, not just name.
    validates :description, length: { maximum: 255 }
    validate :parent_cannot_create_cycle
    validate :parent_must_share_library
    validate :depth_within_limit
    before_destroy :ensure_empty

    # Root-first chain of parents, excluding self.
    def ancestors
      node = parent
      chain = []
      while node
        # Cycle guard — validations prevent cycles, but never loop forever
        # on bad data.
        break if chain.include?(node) || node.id == id
        chain << node
        node = node.parent
      end
      chain.reverse
    end

    # All folders nested under this one (children, grandchildren, ...).
    # Cycle-guarded like #ancestors so bad data can't recurse forever.
    def descendants
      collect_descendants(Set.new([ id ]))
    end

    # 1 for a root folder, 2 for its children, etc.
    def depth
      ancestors.length + 1
    end

    # Human-readable location, e.g. "Team EBT/Q3". This is the shape the
    # API's `folder_path` param speaks, and it stays display-cased — the
    # URL form is #slug_path, which is a different string.
    def path
      (ancestors + [ self ]).map(&:name).join("/")
    end

    # Library-relative URL path, e.g. "team-ebt/q3". Deliberately excludes
    # the library handle so renaming a handle rewrites one library row
    # rather than every folder underneath it.
    def slug_path
      (ancestors + [ self ]).map(&:slug).join("/")
    end

    # Handle-first path, the form URLs and aliases both speak:
    # "orders/team-ebt/q3".
    def url_path
      [ library.handle, slug_path ].compact_blank.join("/")
    end

    # Finds or creates the folder hierarchy for a "/"-separated path like
    # "Team EBT/Q3" inside one library. This is what lets an agent organize
    # a library without pre-creating folders. Raises
    # ActiveRecord::RecordInvalid when the path is too deep or a segment is
    # invalid. Returns nil for a blank path. Lookup is case-insensitive
    # (matching the uniqueness validation); creation preserves the given
    # casing.
    #
    # Pass an array as `created:` to collect the folders this call had to
    # create (root-first) — callers use it to audit implicit creations.
    def self.find_or_create_by_path!(path, library:, created_by_user: nil, created: nil)
      segments = path.to_s.split("/").map(&:strip).reject(&:blank?)
      return nil if segments.empty?

      # Transactional so a failure partway (e.g. "A/B/C/D" exceeding
      # MAX_DEPTH) doesn't leave half-created hierarchy behind.
      transaction do
        segments.reduce(nil) do |parent, name|
          library.folders.where(parent_id: parent&.id).where("LOWER(name) = ?", name.downcase).first ||
            create!(name: name, parent: parent, library: library, created_by_user: created_by_user).tap do |folder|
              created << folder if created
            end
        end
      end
    end

    # Case-insensitive lookup of a "/"-separated path within one library.
    # Returns nil when any segment is missing — the read-only sibling of
    # find_or_create_by_path!.
    def self.find_by_path(path, library:)
      segments = path.to_s.split("/").map(&:strip).reject(&:blank?)
      return nil if segments.empty?

      segments.reduce(nil) do |parent, name|
        folder = library.folders.where(parent_id: parent&.id).where("LOWER(name) = ?", name.downcase).first
        return nil unless folder
        folder
      end
    end

    # Walks a slug path — "team-ebt/q3" — one segment at a time, which is
    # how every browsable URL resolves. Returns the deepest folder, or nil
    # if any segment is missing. Stops at MAX_DEPTH so a long hostile path
    # can't turn into an unbounded query loop.
    def self.find_by_slug_path(slug_path, library:)
      segments = slug_path.to_s.split("/").map(&:strip).reject(&:blank?)
      return nil if segments.empty? || segments.length > MAX_DEPTH

      segments.reduce(nil) do |parent, slug|
        folder = library.folders.find_by(parent_id: parent&.id, slug: slug.downcase)
        return nil unless folder
        folder
      end
    end

    # Full "A/B/C" path for every given folder, keyed by id, computed from
    # the in-memory list (no per-folder queries). Shared by the folders API
    # and the folder-picker helper.
    def self.paths_by_id(folders = order(:name).to_a)
      by_id = folders.index_by(&:id)
      folders.index_with do |folder|
        names = [ folder.name ]
        seen = Set.new([ folder.id ])
        node = folder
        while node.parent_id && (node = by_id[node.parent_id])
          break unless seen.add?(node.id) # cycle guard on bad data
          names.unshift(node.name)
        end
        names.join("/")
      end.transform_keys(&:id)
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id name slug description library_id parent_id created_by_user_id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[library parent children placements plans created_by_user]
    end

    private

    def broadcast_folder_change
      broadcast_library_refresh(library)
    end

    # Follows the name. A rename is rare and its old URL keeps resolving
    # via UrlAlias, so the segment tracking the current name is worth more
    # than a frozen one.
    def assign_slug
      return if name.blank?
      return unless slug.blank? || will_save_change_to_name?

      self.slug = CoPlan::Slug.call(name).presence || "folder"
    end

    # Captured before the write, because afterwards `ancestors` walks the
    # *new* parent chain and the old path is no longer reconstructible.
    def stash_previous_url_path
      @previous_url_path = nil
      return if new_record?
      return unless will_save_change_to_slug? || will_save_change_to_parent_id?

      old_slug = slug_in_database
      return if old_slug.blank?

      old_parent = parent_id_in_database.present? ? Folder.find_by(id: parent_id_in_database) : nil
      @previous_url_path = [ library.handle, old_parent&.slug_path, old_slug ].compact_blank.join("/")
    end

    def record_url_alias
      return if @previous_url_path.blank?

      UrlAlias.record!(from: @previous_url_path, to: url_path, kind: "prefix")
      @previous_url_path = nil
    end

    def parent_cannot_create_cycle
      return if parent_id.blank?

      if parent_id == id
        errors.add(:parent, "cannot be the folder itself")
        return
      end

      node = parent
      seen = Set.new
      while node
        if node.id == id
          errors.add(:parent, "cannot be one of the folder's own subfolders")
          return
        end
        break unless seen.add?(node.id)
        node = node.parent
      end
    end

    def parent_must_share_library
      return if parent.nil?
      return if parent.library_id == library_id

      errors.add(:parent, "must belong to the same library")
    end

    def depth_within_limit
      return if parent.nil?
      # Skip when a cycle error is already present — depth would loop.
      return if errors[:parent].any?

      height = persisted? ? subtree_height(Set.new([ id ])) : 0
      if parent.depth + 1 + height > MAX_DEPTH
        errors.add(:parent, "would exceed the maximum folder depth of #{MAX_DEPTH}")
      end
    end

    def ensure_empty
      if placements.exists?
        errors.add(:base, "Cannot delete a folder that contains plans — move the plans out first")
        throw :abort
      end
      if children.exists?
        errors.add(:base, "Cannot delete a folder that contains subfolders — delete or move them first")
        throw :abort
      end
    end

    protected

    # Levels of subfolders below this one (0 when it has none). Used to
    # measure subtree height when re-parenting a folder that already has
    # children. `visited` guards against cycles in bad data.
    def subtree_height(visited)
      kids = children.reject { |child| visited.include?(child.id) }
      return 0 if kids.empty?

      1 + kids.map { |child| child.subtree_height(visited << child.id) }.max
    end

    def collect_descendants(visited)
      children.reject { |child| visited.include?(child.id) }.flat_map do |child|
        visited << child.id
        [ child ] + child.collect_descendants(visited)
      end
    end
  end
end
