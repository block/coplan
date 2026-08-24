class BackfillPlanSlugs < ActiveRecord::Migration[8.1]
  # Gives every plan the readable leaf segment of its address, and makes
  # a plan without one unrepresentable.
  #
  # AddPlanSlugsAndUrlAliases deliberately left slugs NULL and let the app
  # fill them in on the next save. The cost turned out to be a permanent
  # second address: a plan nobody has re-saved since has no readable path
  # at all, so every link to it — and its rel=canonical — falls back to
  # /plans/<uuid>. A document has one address, so the backfill has to
  # actually happen.
  #
  # The slug rules are inlined below rather than called through
  # CoPlan::Slug and Plans::AssignSlug, for the same reason the folder and
  # handle backfills inline theirs: a migration has to keep producing the
  # same result years from now, even after the app's rules move on.
  #
  # No aliases are recorded. These plans never had a readable address, so
  # there's no old path anyone could be holding — the legacy /plans/<uuid>
  # route is what their existing links go through, and it 301s onward.

  # Mirrors CoPlan::Slug.
  MAX_LENGTH = 60
  NOISE_TOKENS = %w[plan plans doc document].freeze
  # Mirrors Plans::AssignSlug. Unambiguous alphabet — no 0/o/1/l.
  SUFFIX_ALPHABET = "23456789abcdefghjkmnpqrstuvwxyz".freeze
  SUFFIX_LENGTH = 4

  def up
    backfill_plan_slugs
    change_column_null :coplan_plans, :slug, false
  end

  def down
    change_column_null :coplan_plans, :slug, true
  end

  private

  # Two passes. The first registers the slugs already in use at each level
  # so the backfill can't collide with them; the second assigns the rest,
  # oldest first, so the earliest plan keeps the clean un-suffixed segment.
  def backfill_plan_slugs
    folders = load_folders
    libraries = load_library_handles
    plan_types = load_plan_type_names
    locations = load_plan_locations
    creator_libraries = load_creator_libraries

    plans = connection.select_all(<<~SQL.squish).to_a
      SELECT id, title, slug, slug_suffix, plan_type_id, created_by_user_id, created_at
      FROM coplan_plans
      ORDER BY created_at, id
    SQL

    # Sibling folder slugs are taken too: Urls::Resolve hands a contested
    # segment to the folder, so a plan sharing one would have no reachable
    # address. Folders never take a suffix; plans do.
    taken = {}
    folders.each_value do |folder|
      key = [ folder["library_id"], folder["parent_id"] ]
      (taken[key] ||= Set.new) << folder["slug"]
    end

    pending = []
    plans.each do |plan|
      library_id, folder_id = location_for(plan, locations, creator_libraries)
      key = [ library_id, folder_id ]
      if plan["slug"].present?
        seen = (taken[key] ||= Set.new)
        # Only an un-suffixed slug blocks the segment; a suffixed one has
        # already moved out of the way. Its full leaf is still spoken for
        # though, so it goes in too — otherwise a backfilled plan whose
        # deterministic candidate happens to match would be handed the
        # same address, and nothing downstream would reject it.
        if plan["slug_suffix"].blank?
          seen << plan["slug"]
        else
          seen << "#{plan['slug']}~#{plan['slug_suffix']}"
        end
        next
      end
      pending << [ plan, key, folder_id, library_id ]
    end

    say "Backfilling slugs for #{pending.size} plan(s)" if pending.any?
    pending.each do |plan, key, folder_id, library_id|
      slug = derive_slug(
        plan["title"],
        redundant_phrases(library_id, folder_id, plan["plan_type_id"], folders, libraries, plan_types)
      )
      seen = (taken[key] ||= Set.new)
      if seen.include?(slug)
        suffix = unique_suffix(plan["id"], slug, seen)
        write_slug(plan["id"], slug, suffix)
        seen << "#{slug}~#{suffix}"
      else
        write_slug(plan["id"], slug, nil)
        seen << slug
      end
    end
  end

  def write_slug(plan_id, slug, suffix)
    execute <<~SQL.squish
      UPDATE coplan_plans
      SET slug = #{quote(slug)}, slug_suffix = #{suffix ? quote(suffix) : "NULL"}
      WHERE id = #{quote(plan_id)}
    SQL
  end

  # Where the plan lives: its placement when it has one, otherwise the
  # root of its author's library — which is exactly what Plan#library
  # resolves to, and what its URL says.
  def location_for(plan, locations, creator_libraries)
    placement = locations[plan["id"]]
    return [ placement["library_id"], placement["folder_id"] ] if placement

    [ creator_libraries[plan["created_by_user_id"]], nil ]
  end

  # Everything the path already spells out: the handle, every folder on
  # the way down, and the plan type.
  def redundant_phrases(library_id, folder_id, plan_type_id, folders, libraries, plan_types)
    names = []
    folder_id_walk = folder_id
    while folder_id_walk && (folder = folders[folder_id_walk])
      names.unshift(folder["name"])
      folder_id_walk = folder["parent_id"]
    end

    [ libraries[library_id], *names, plan_types[plan_type_id] ].compact_blank
  end

  # --- The slug rules, inlined ---------------------------------------

  def derive_slug(title, phrases)
    full = strip_noise(slug_tokens(title))
    return "untitled" if full.empty?

    truncate(strip_redundancy(full, phrases).join("-"))
  end

  def slugify(text)
    normalize(text.to_s.unicode_normalize(:nfc).downcase.gsub(/[^[[:alnum:]]]+/, "-"))
  end

  def normalize(hyphenated)
    truncate(hyphenated.gsub(/-{2,}/, "-").delete_prefix("-").delete_suffix("-"))
  end

  def truncate(slug)
    return slug if slug.length <= MAX_LENGTH

    slug[0, MAX_LENGTH].rpartition("-").first.presence || slug[0, MAX_LENGTH]
  end

  def slug_tokens(text)
    slugify(text).split("-")
  end

  def compare_key(text)
    slugify(text).delete("-")
  end

  def strip_noise(tokens)
    kept = tokens.dup
    kept.shift while kept.size > 1 && NOISE_TOKENS.include?(kept.first)
    kept.pop while kept.size > 1 && NOISE_TOKENS.include?(kept.last)
    kept.presence || tokens
  end

  # Repeats until nothing more comes off, so "Orders LiveOrder Cart"
  # under /orders/liveorder loses both leading words regardless of the
  # order they appear in.
  def strip_redundancy(tokens, phrases)
    kept = tokens
    loop do
      before = kept
      phrases.each { |phrase| kept = strip_leading(kept, phrase) }
      break if kept == before
    end
    kept.presence || tokens
  end

  # Never strips everything — a plan titled exactly "LiveOrder" inside
  # "LiveOrder" keeps its name rather than becoming empty.
  def strip_leading(tokens, phrase)
    key = compare_key(phrase)
    return tokens if key.blank?

    (1...tokens.length).each do |n|
      return tokens.drop(n) if tokens.first(n).join == key
    end
    tokens
  end

  # Derived from the plan id rather than random: re-running this migration
  # on the same data has to produce the same URLs.
  def unique_suffix(plan_id, slug, seen)
    attempt = 0
    loop do
      candidate = suffix_for(plan_id, attempt)
      return candidate unless seen.include?("#{slug}~#{candidate}")

      attempt += 1
    end
  end

  def suffix_for(plan_id, attempt)
    digest = Digest::SHA256.hexdigest("#{plan_id}:#{attempt}").to_i(16)
    SUFFIX_LENGTH.times.map do |index|
      SUFFIX_ALPHABET[(digest >> (index * 8)) % SUFFIX_ALPHABET.length]
    end.join
  end

  # --- Reads ---------------------------------------------------------

  def load_folders
    connection.select_all(<<~SQL.squish).to_a.index_by { |row| row["id"] }
      SELECT id, library_id, parent_id, name, slug FROM coplan_folders
    SQL
  end

  def load_library_handles
    connection.select_all("SELECT id, handle FROM coplan_libraries").to_a
      .to_h { |row| [ row["id"], row["handle"] ] }
  end

  def load_plan_type_names
    connection.select_all("SELECT id, name FROM coplan_plan_types").to_a
      .to_h { |row| [ row["id"], row["name"] ] }
  end

  def load_plan_locations
    connection.select_all(<<~SQL.squish).to_a.index_by { |row| row["plan_id"] }
      SELECT plan_id, library_id, folder_id FROM coplan_plan_placements
    SQL
  end

  def load_creator_libraries
    connection.select_all(<<~SQL.squish).to_a
      SELECT owner_id, id FROM coplan_libraries WHERE owner_type = 'CoPlan::User'
    SQL
      .to_h { |row| [ row["owner_id"], row["id"] ] }
  end

  def quote(value)
    connection.quote(value)
  end
end
