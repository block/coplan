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

    validates :name, presence: true,
      uniqueness: { scope: [ :library_id, :parent_id ], case_sensitive: false },
      format: { with: NAME_FORMAT, message: "cannot contain \"/\"" },
      length: { maximum: 100 }
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

    # Human-readable location, e.g. "Team EBT/Q3".
    def path
      (ancestors + [ self ]).map(&:name).join("/")
    end

    # Finds or creates the folder hierarchy for a "/"-separated path like
    # "Team EBT/Q3" inside one library. This is what lets an agent organize
    # a library without pre-creating folders. Raises
    # ActiveRecord::RecordInvalid when the path is too deep or a segment is
    # invalid. Returns nil for a blank path. Lookup is case-insensitive
    # (matching the uniqueness validation); creation preserves the given
    # casing.
    def self.find_or_create_by_path!(path, library:, created_by_user: nil)
      segments = path.to_s.split("/").map(&:strip).reject(&:blank?)
      return nil if segments.empty?

      # Transactional so a failure partway (e.g. "A/B/C/D" exceeding
      # MAX_DEPTH) doesn't leave half-created hierarchy behind.
      transaction do
        segments.reduce(nil) do |parent, name|
          library.folders.where(parent_id: parent&.id).where("LOWER(name) = ?", name.downcase).first ||
            create!(name: name, parent: parent, library: library, created_by_user: created_by_user)
        end
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
      %w[id name library_id parent_id created_by_user_id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[library parent children placements plans created_by_user]
    end

    private

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
