class AddPlanSlugsAndUrlAliases < ActiveRecord::Migration[8.1]
  # The leaf segment of a browsable URL, plus the table that keeps old
  # URLs resolving.
  #
  # `slug` is derived from the plan's title with redundancy stripped — a
  # plan titled "LiveOrder Cart Roadmap" filed in "LiveOrder" is just
  # "cart-roadmap", because the folder already said the rest.
  # `slug_suffix` is set only when two plans in the same folder want the
  # same slug, so it appears in a URL only where it earns something.
  #
  # No unique index on (slug, slug_suffix): a plan's uniqueness scope is
  # the folder it's filed in, which lives in coplan_plan_placements, not
  # here. Uniqueness is enforced on write against the canonical folder
  # (Plans::AssignSlug). A real DB constraint becomes possible once a plan
  # is filed in exactly one library — see the placements collapse.
  #
  # Backfill leaves slugs NULL and lets the app fill them in lazily, so
  # this migration stays fast on a large table and doesn't have to
  # reimplement the redundancy-stripping rules.
  def up
    add_column :coplan_plans, :slug, :string
    add_column :coplan_plans, :slug_suffix, :string, limit: 8
    add_index :coplan_plans, [ :slug, :slug_suffix ], name: "index_coplan_plans_on_slug_and_suffix"

    create_table :coplan_url_aliases, id: { type: :string, limit: 36 } do |t|
      # The stale path, library handle first and no leading slash:
      # "orders/liveorder/cart-roadmap".
      t.string :path, null: false, limit: 512
      # "exact" matches one URL; "prefix" rewrites everything beneath it,
      # which is how one row covers a renamed folder's whole subtree.
      t.string :kind, null: false, default: "exact"
      t.string :target_path, null: false, limit: 512
      # Cheap eviction signal: rows nobody has ever followed are safe to
      # drop, because plan_events / library_events can rebuild them.
      t.integer :resolve_count, null: false, default: 0
      t.timestamp :last_resolved_at
      t.timestamps
    end
    add_index :coplan_url_aliases, [ :path, :kind ], unique: true,
      name: "index_coplan_url_aliases_on_path_and_kind"
    add_index :coplan_url_aliases, [ :kind, :resolve_count, :created_at ],
      name: "index_coplan_url_aliases_for_pruning"
  end

  def down
    drop_table :coplan_url_aliases
    remove_index :coplan_plans, name: "index_coplan_plans_on_slug_and_suffix"
    remove_column :coplan_plans, :slug_suffix
    remove_column :coplan_plans, :slug
  end
end
