class CreateLibrariesAndPlacements < ActiveRecord::Migration[8.1]
  class MigrationFolder < ActiveRecord::Base
    self.table_name = "coplan_folders"
  end

  class MigrationLibrary < ActiveRecord::Base
    self.table_name = "coplan_libraries"
    before_create { self.id ||= SecureRandom.uuid_v7 }
  end

  class MigrationPlacement < ActiveRecord::Base
    self.table_name = "coplan_plan_placements"
    before_create { self.id ||= SecureRandom.uuid_v7 }
  end

  class MigrationPlan < ActiveRecord::Base
    self.table_name = "coplan_plans"
  end

  def up
    # A library is the owner-shaped container for a folder tree. Owner is
    # polymorphic: users in v1, teams (or other group types) later.
    create_table :coplan_libraries, id: { type: :string, limit: 36 } do |t|
      t.string :owner_type, null: false
      t.string :owner_id, limit: 36, null: false
      t.string :name, null: false, default: "Library"
      t.timestamps

      # One library per owner (v1). Relax deliberately if/when multiple
      # libraries per owner become a real product need.
      t.index [ :owner_type, :owner_id ], unique: true
    end

    add_column :coplan_folders, :library_id, :string, limit: 36
    add_index :coplan_folders, :library_id

    # A placement shelves a plan in a folder. It is the viewer's organization
    # of the plan, not a property of the plan itself: the same plan can sit
    # in many libraries at once. library_id is denormalized from the folder
    # so "one spot per library" is enforceable with a unique index.
    create_table :coplan_plan_placements, id: { type: :string, limit: 36 } do |t|
      t.string :plan_id, limit: 36, null: false
      t.string :folder_id, limit: 36, null: false
      t.string :library_id, limit: 36, null: false
      t.string :placed_by_user_id, limit: 36
      t.timestamps

      t.index [ :plan_id, :library_id ], unique: true
      t.index :folder_id
      t.index :library_id
    end

    # The org-global folder design (#145) never reached production, so this
    # backfill only matters for development databases: each folder joins its
    # creator's library, creator-less folders are dropped (dev debris), and
    # plans' single folder_id becomes a placement.
    MigrationFolder.reset_column_information
    MigrationFolder.where(created_by_user_id: nil).delete_all
    MigrationFolder.find_each do |folder|
      library = MigrationLibrary.find_or_create_by!(
        owner_type: "CoPlan::User",
        owner_id: folder.created_by_user_id
      )
      folder.update_columns(library_id: library.id)
    end

    MigrationPlan.where.not(folder_id: nil).find_each do |plan|
      folder = MigrationFolder.find_by(id: plan.folder_id)
      next unless folder&.library_id

      MigrationPlacement.create!(
        plan_id: plan.id,
        folder_id: folder.id,
        library_id: folder.library_id,
        placed_by_user_id: plan.created_by_user_id
      )
    end

    change_column_null :coplan_folders, :library_id, false

    # Folder names are unique per parent within a library now (two people
    # can both have a root "Projects" folder). The parent_id FK needs an
    # index leading with parent_id, which the old composite provided — add
    # a plain one before MySQL will let the composite go.
    add_index :coplan_folders, :parent_id
    remove_index :coplan_folders, column: [ :parent_id, :name ], unique: true
    add_index :coplan_folders, [ :library_id, :parent_id, :name ], unique: true

    remove_foreign_key :coplan_plans, :coplan_folders, column: :folder_id
    remove_index :coplan_plans, :folder_id
    remove_column :coplan_plans, :folder_id

    add_foreign_key :coplan_folders, :coplan_libraries, column: :library_id
    add_foreign_key :coplan_plan_placements, :coplan_plans, column: :plan_id
    add_foreign_key :coplan_plan_placements, :coplan_folders, column: :folder_id
    add_foreign_key :coplan_plan_placements, :coplan_libraries, column: :library_id
    add_foreign_key :coplan_plan_placements, :coplan_users, column: :placed_by_user_id
  end

  def down
    add_column :coplan_plans, :folder_id, :string, limit: 36
    add_index :coplan_plans, :folder_id
    add_foreign_key :coplan_plans, :coplan_folders, column: :folder_id

    # Restore each plan's author-library placement as its folder, then drop
    # the placement machinery.
    MigrationPlacement.reset_column_information
    MigrationPlacement.find_each do |placement|
      plan = MigrationPlan.find_by(id: placement.plan_id)
      next unless plan && plan.created_by_user_id == placement.placed_by_user_id

      plan.update_columns(folder_id: placement.folder_id)
    end

    remove_index :coplan_folders, column: [ :library_id, :parent_id, :name ], unique: true
    add_index :coplan_folders, [ :parent_id, :name ], unique: true
    remove_index :coplan_folders, :parent_id
    remove_foreign_key :coplan_folders, :coplan_libraries, column: :library_id
    remove_column :coplan_folders, :library_id

    drop_table :coplan_plan_placements
    drop_table :coplan_libraries
  end
end
