class CollapsePlanPlacementsToOne < ActiveRecord::Migration[8.1]
  # A plan now lives in exactly one library. The old model let the same
  # plan sit on many shelves at once — filing someone else's published
  # plan into your own library was a "bookmark", separate from the
  # author's copy. In practice nobody used it, and it cost us the one
  # property a readable URL needs: a document having a single address.
  #
  # Collapses existing rows, keeping the author's own placement where
  # there is one (that's the shelf URLs already resolved to) and
  # otherwise the oldest, then makes more than one unrepresentable.
  def up
    ids = surplus_placement_ids
    say "Dropping #{ids.size} non-canonical placement(s)" if ids.any?
    ids.each_slice(500) do |batch|
      execute <<~SQL.squish
        DELETE FROM coplan_plan_placements
        WHERE id IN (#{batch.map { |id| quote(id) }.join(",")})
      SQL
    end

    # The new index subsumes index_..._on_plan_id_and_library_id, the old
    # "one shelf per library" constraint. Added before the old one is
    # dropped: MySQL requires an index on plan_id for its foreign key and
    # refuses to drop the last one that satisfies it.
    add_index :coplan_plan_placements, :plan_id, unique: true,
      name: "index_coplan_plan_placements_on_plan_id"
    remove_index :coplan_plan_placements, column: [ :plan_id, :library_id ]
  end

  def down
    add_index :coplan_plan_placements, [ :plan_id, :library_id ], unique: true,
      name: "index_coplan_plan_placements_on_plan_id_and_library_id"
    remove_index :coplan_plan_placements, column: :plan_id
  end

  private

  # Grouped in Ruby rather than SQL: picking a winner per plan needs a
  # correlated "is this the author's library" test, and the portable
  # forms of that are worse than reading the table. Placement counts are
  # in the thousands at most.
  def surplus_placement_ids
    rows = connection.select_all(<<~SQL.squish).to_a
      SELECT pp.id AS id, pp.plan_id AS plan_id, pp.created_at AS created_at,
             lib.owner_type AS owner_type, lib.owner_id AS owner_id,
             p.created_by_user_id AS author_id
      FROM coplan_plan_placements pp
      INNER JOIN coplan_plans p ON p.id = pp.plan_id
      INNER JOIN coplan_libraries lib ON lib.id = pp.library_id
    SQL

    rows.group_by { |row| row["plan_id"] }.flat_map do |_plan_id, group|
      next [] if group.size < 2

      keeper = group.find { |row| authors_own?(row) } || group.min_by { |row| row["created_at"].to_s }
      (group - [ keeper ]).map { |row| row["id"] }
    end
  end

  def authors_own?(row)
    row["owner_type"] == "CoPlan::User" && row["owner_id"].to_s == row["author_id"].to_s
  end

  def quote(value)
    connection.quote(value)
  end
end
