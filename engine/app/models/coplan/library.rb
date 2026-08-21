module CoPlan
  # A library is the owner-shaped container for a folder tree and the
  # placements filed into it. Every user always has one — it's an invariant,
  # not a feature: `Library.for(owner)` materializes it on first touch, so
  # "user without a library" is not a state that exists anywhere else in
  # the app.
  #
  # Ownership is polymorphic on purpose. Users are the only owner type
  # today, but a team library later is a new owner type on this same model,
  # not a new system — so no query or policy outside this class should
  # assume owner == user. Write policy lives here (`writable_by?`), which
  # is exactly where "who may file things into this library" belongs.
  #
  # `handle` is the library's URL segment — the root of everything
  # browsable under /l/<handle>. It is the segment that carries the most
  # weight in a shared link, so it stays short and typeable.
  class Library < ApplicationRecord
    # Because libraries live under /l, a handle can never collide with an
    # app route — the only names worth reserving are ones that would make
    # a future /l/<verb> route ambiguous. Hosts add their own via
    # `config.reserved_handles`.
    RESERVED_HANDLES = %w[new edit all api admin].freeze
    HANDLE_FORMAT = /\A[a-z0-9][a-z0-9-]*\z/
    HANDLE_MAX_LENGTH = 60

    belongs_to :owner, polymorphic: true
    has_many :folders, class_name: "CoPlan::Folder", dependent: :destroy
    has_many :placements, class_name: "CoPlan::PlanPlacement", dependent: :destroy
    # Append-only audit rows; delete_all (not destroy) — no callbacks to run,
    # and the FK would otherwise block destroying the library.
    has_many :library_events, class_name: "CoPlan::LibraryEvent", dependent: :delete_all

    # Assigned before validation so callers never have to supply one —
    # `Library.for(owner)` keeps its one-argument shape.
    before_validation :assign_handle, on: :create
    # Renaming a handle is one prefix alias for the entire library, since
    # no folder or plan stores the handle in its own path.
    after_save :record_handle_alias, if: :saved_change_to_handle?

    validates :name, presence: true, length: { maximum: 100 }
    validates :owner_id, uniqueness: { scope: :owner_type }
    validates :handle, presence: true, uniqueness: { case_sensitive: false },
      length: { maximum: HANDLE_MAX_LENGTH },
      format: { with: HANDLE_FORMAT, message: "may use only lowercase letters, numbers, and hyphens" }
    validate :handle_not_reserved

    class << self
      def for(owner)
        find_or_create_by!(owner: owner)
      rescue ActiveRecord::RecordNotUnique
        # Two requests materialized the same owner's library at once — the
        # unique [owner_type, owner_id] index makes the loser retry the read.
        find_by!(owner: owner)
      end

      def reserved_handles
        RESERVED_HANDLES + Array(CoPlan.configuration.reserved_handles).map { |h| h.to_s.downcase }
      end

      # Case-insensitive so a pasted /l/Orders link still lands.
      def find_by_handle(handle)
        return nil if handle.blank?

        find_by(handle: handle.to_s.downcase)
      end

      # First unclaimed handle at or after `base`, so handle assignment
      # never fails on a collision.
      def unclaimed_handle(base)
        candidate = CoPlan::Slug.call(base).presence || "library"
        return candidate unless handle_claimed?(candidate)

        suffix = 2
        suffix += 1 while handle_claimed?("#{candidate}-#{suffix}")
        "#{candidate}-#{suffix}"
      end

      def handle_claimed?(candidate)
        reserved_handles.include?(candidate) || exists?(handle: candidate)
      end

      def ransackable_attributes(_auth_object = nil)
        %w[id owner_type owner_id name handle created_at updated_at]
      end

      def ransackable_associations(_auth_object = nil)
        %w[owner folders placements]
      end
    end

    # What this library shows at its root: the owner's own work that isn't
    # filed into any folder here. "Unfiled" means no placement row at all,
    # which is why these plans are addressed directly under the handle —
    # /l/orders/some-plan — with no folder segment in between.
    #
    # Callers add their own visibility filter; this answers location, not
    # who may see it.
    def unfiled_plans
      return Plan.none unless owner_type == "CoPlan::User"

      Plan.where(created_by_user_id: owner_id)
        .where.not(id: placements.select(:plan_id))
    end

    # Only the owner writes to a personal library. A future team library
    # answers this with membership instead — callers just ask the library.
    def writable_by?(user)
      return false unless user

      owner_type == "CoPlan::User" && owner_id == user.id
    end

    private

    # A personal library takes its owner's username — their ldap — so the
    # default handle is the name they already answer to. A team library
    # uses the library's own name.
    def assign_handle
      return if handle.present?

      self.handle = self.class.unclaimed_handle(handle_source)
    end

    def handle_source
      if owner.is_a?(CoPlan::User)
        owner.username.presence || owner.email.to_s.split("@").first.presence || owner.name
      else
        name
      end
    end

    def handle_not_reserved
      return if handle.blank?

      errors.add(:handle, "is reserved") if self.class.reserved_handles.include?(handle.downcase)
    end

    def record_handle_alias
      previous, current = saved_change_to_handle
      return if previous.blank? || current.blank?

      UrlAlias.record!(from: previous, to: current, kind: "prefix")
    end
  end
end
