module CoPlan
  # A shared, org-wide location for plans — Dropbox Paper / Google Docs style.
  # Folders form a small hierarchy (max MAX_DEPTH levels) and each plan lives
  # in at most one folder (Plan#folder_id). Tags remain the cross-cutting
  # labels; folders answer "where does this plan live?".
  #
  # Anyone signed in can create folders and move their own plans into or out
  # of any folder. Rename/delete is limited to the folder's creator or an
  # admin (see FolderPolicy).
  class Folder < ApplicationRecord
    MAX_DEPTH = 3

    # "/" is reserved as the path separator for folder_path lookups
    # (e.g. "Team EBT/Q3"), so it can't appear in a folder name.
    NAME_FORMAT = %r{\A[^/]+\z}

    belongs_to :parent, class_name: "CoPlan::Folder", optional: true, inverse_of: :children
    has_many :children, class_name: "CoPlan::Folder", foreign_key: :parent_id,
      inverse_of: :parent, dependent: nil
    belongs_to :created_by_user, class_name: "CoPlan::User", optional: true
    has_many :plans, class_name: "CoPlan::Plan", foreign_key: :folder_id,
      inverse_of: :folder, dependent: nil

    validates :name, presence: true,
      uniqueness: { scope: :parent_id, case_sensitive: false },
      format: { with: NAME_FORMAT, message: "cannot contain \"/\"" },
      length: { maximum: 100 }
    validate :parent_cannot_create_cycle
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
    def descendants
      children.flat_map { |child| [child] + child.descendants }
    end

    # 1 for a root folder, 2 for its children, etc.
    def depth
      ancestors.length + 1
    end

    # Human-readable location, e.g. "Team EBT/Q3".
    def path
      (ancestors + [self]).map(&:name).join("/")
    end

    # Finds or creates the folder hierarchy for a "/"-separated path like
    # "Team EBT/Q3". This is what lets an AI librarian agent organize plans
    # without pre-creating folders. Raises ActiveRecord::RecordInvalid when
    # the path is too deep or a segment is invalid. Returns nil for a blank
    # path. Lookup is case-insensitive (matching the uniqueness validation);
    # creation preserves the given casing.
    def self.find_or_create_by_path!(path, created_by_user: nil)
      segments = path.to_s.split("/").map(&:strip).reject(&:blank?)
      return nil if segments.empty?

      segments.reduce(nil) do |parent, name|
        where(parent_id: parent&.id).where("LOWER(name) = ?", name.downcase).first ||
          create!(name: name, parent: parent, created_by_user: created_by_user)
      end
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id name parent_id created_by_user_id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[parent children plans created_by_user]
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

    def depth_within_limit
      return if parent.nil?
      # Skip when a cycle error is already present — depth would loop.
      return if errors[:parent].any?

      subtree_height = persisted? ? ([0] + descendants.map { |d| d.ancestors_until(self).length + 1 }).max : 0
      if parent.depth + 1 + subtree_height > MAX_DEPTH
        errors.add(:parent, "would exceed the maximum folder depth of #{MAX_DEPTH}")
      end
    end

    def ensure_empty
      if plans.exists?
        errors.add(:base, "Cannot delete a folder that contains plans — move the plans out first")
        throw :abort
      end
      if children.exists?
        errors.add(:base, "Cannot delete a folder that contains subfolders — delete or move them first")
        throw :abort
      end
    end

    protected

    # Number of ancestors strictly below `stop` (used to measure subtree
    # height when re-parenting a folder that already has children).
    def ancestors_until(stop)
      node = parent
      chain = []
      while node && node.id != stop.id
        break if chain.include?(node)
        chain << node
        node = node.parent
      end
      chain
    end
  end
end
