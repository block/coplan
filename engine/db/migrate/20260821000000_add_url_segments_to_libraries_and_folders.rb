class AddUrlSegmentsToLibrariesAndFolders < ActiveRecord::Migration[8.1]
  # Gives libraries and folders the URL segments that make them browsable:
  # /l/<handle>/<folder-slug>/<folder-slug>. Resolution walks these one
  # segment at a time, so nothing stores a joined path and renaming a
  # folder touches only its own row.
  #
  # Slug logic is inlined rather than calling CoPlan::Slug — a migration
  # has to keep producing the same backfill years from now, even if the
  # app's slug rules move on.
  #
  # Raw portable SQL throughout (select_all / quote), same reasoning as
  # RequirePlanTypeOnCoplanPlans: this runs on MySQL and PostgreSQL hosts.
  #
  # Note on the unique indexes: MySQL treats NULLs as distinct, so the
  # folder index does not actually constrain root folders (parent_id
  # NULL). Real enforcement is the Rails validation, which scopes with
  # IS NULL correctly — matching how `name` uniqueness already works on
  # this table. The index is for lookup speed on the resolver's hot path.
  def up
    add_column :coplan_libraries, :handle, :string
    add_column :coplan_folders, :slug, :string

    backfill_library_handles
    backfill_folder_slugs

    change_column_null :coplan_libraries, :handle, false
    change_column_null :coplan_folders, :slug, false
    add_index :coplan_libraries, :handle, unique: true, name: "index_coplan_libraries_on_handle"
    add_index :coplan_folders, [ :library_id, :parent_id, :slug ],
      unique: true, name: "index_coplan_folders_on_library_and_parent_and_slug"
  end

  def down
    remove_index :coplan_folders, name: "index_coplan_folders_on_library_and_parent_and_slug"
    remove_index :coplan_libraries, name: "index_coplan_libraries_on_handle"
    remove_column :coplan_folders, :slug
    remove_column :coplan_libraries, :handle
  end

  private

  # A personal library's handle comes from the owner's username (their
  # ldap), falling back to the email local part and then the display
  # name. Anything else — a team library — uses the library's own name.
  def backfill_library_handles
    rows = connection.select_all(<<~SQL)
      SELECT l.id, l.name, l.owner_type, l.owner_id,
             u.username AS owner_username, u.email AS owner_email, u.name AS owner_name
      FROM coplan_libraries l
      LEFT JOIN coplan_users u
        ON l.owner_type = 'CoPlan::User' AND l.owner_id = u.id
      ORDER BY l.created_at, l.id
    SQL

    taken = []
    rows.each do |row|
      source = row["owner_username"].presence ||
        row["owner_email"].to_s.split("@").first.presence ||
        row["owner_name"].presence ||
        row["name"].presence ||
        "library"
      handle = unique_slug(ascii_slugify(source), taken, fallback: "library")
      taken << handle
      execute "UPDATE coplan_libraries SET handle = #{quote(handle)} WHERE id = #{quote(row['id'])}"
    end
  end

  # Folder slugs only have to be unique among siblings, so uniqueness is
  # tracked per (library, parent). Deepest-last ordering isn't needed —
  # a folder's slug depends on its own name alone.
  def backfill_folder_slugs
    rows = connection.select_all(<<~SQL)
      SELECT id, library_id, parent_id, name
      FROM coplan_folders
      ORDER BY library_id, parent_id, created_at, id
    SQL

    taken = {}
    rows.each do |row|
      sibling_key = [ row["library_id"], row["parent_id"] ]
      taken[sibling_key] ||= []
      slug = unique_slug(slugify(row["name"]), taken[sibling_key], fallback: "folder")
      taken[sibling_key] << slug
      execute "UPDATE coplan_folders SET slug = #{quote(slug)} WHERE id = #{quote(row['id'])}"
    end
  end

  # Mirrors CoPlan::Slug.call / .handle, inlined so this backfill keeps
  # producing the same slugs if the app's rules move on. Folders keep
  # Unicode letters — a folder named 設計 gets a segment that says so —
  # while handles stay ASCII because they're typed and read aloud.
  def slugify(text)
    trim(text.to_s.unicode_normalize(:nfc).downcase.gsub(/[^[[:alnum:]]]+/, "-"))
  end

  def ascii_slugify(text)
    trim(text.to_s.unicode_normalize(:nfkd).downcase.gsub(/[^a-z0-9]+/, "-"))
  end

  def trim(hyphenated)
    hyphenated.gsub(/-{2,}/, "-").delete_prefix("-").delete_suffix("-")[0, 60].to_s
      .delete_suffix("-")
  end

  # Existing data predates any slug rule, so collisions are expected —
  # "Team EBT" and "team-ebt" both want the same segment. Numeric
  # suffixes here are a backfill concession; new records get better
  # disambiguation from the app.
  def unique_slug(slug, taken, fallback:)
    candidate = slug.presence || fallback
    return candidate unless taken.include?(candidate)

    suffix = 2
    suffix += 1 while taken.include?("#{candidate}-#{suffix}")
    "#{candidate}-#{suffix}"
  end
end
