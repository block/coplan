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
  class Library < ApplicationRecord
    belongs_to :owner, polymorphic: true
    has_many :folders, class_name: "CoPlan::Folder", dependent: :destroy
    has_many :placements, class_name: "CoPlan::PlanPlacement", dependent: :destroy

    validates :name, presence: true, length: { maximum: 100 }
    validates :owner_id, uniqueness: { scope: :owner_type }

    def self.for(owner)
      find_or_create_by!(owner: owner)
    rescue ActiveRecord::RecordNotUnique
      # Two requests materialized the same owner's library at once — the
      # unique [owner_type, owner_id] index makes the loser retry the read.
      find_by!(owner: owner)
    end

    # Only the owner writes to a personal library. A future team library
    # answers this with membership instead — callers just ask the library.
    def writable_by?(user)
      return false unless user

      owner_type == "CoPlan::User" && owner_id == user.id
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id owner_type owner_id name created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[owner folders placements]
    end
  end
end
