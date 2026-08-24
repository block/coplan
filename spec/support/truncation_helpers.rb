# Adapter-portable TRUNCATE for the search specs, which run without
# transactional fixtures (InnoDB FULLTEXT writes are invisible to
# MATCH … AGAINST inside the same transaction) and so must clean up manually.
module TruncationHelpers
  # Everything a plan-and-author fixture touches, children before parents
  # (only the SQLite branch below cares about the order).
  #
  # Libraries and folders belong here even though no such example reads
  # them: a library handle is globally unique, so a leaked row keeps
  # "alice" reserved and the *next* spec's alice quietly gets a different
  # URL. Truncating users without them leaves exactly that orphan.
  #
  # Plan events are here for a related reason: filing a plan writes one,
  # and a leaked event is invisible to the spec that leaked it but shows up
  # as an extra row in the next spec that counts them.
  PLAN_TABLES = %w[
    coplan_plan_tags
    coplan_tags
    coplan_plan_placements
    coplan_plan_events
    coplan_plan_versions
    coplan_plans
    coplan_folders
    coplan_library_events
    coplan_libraries
    coplan_url_aliases
    coplan_plan_types
    coplan_search_queries
    coplan_users
  ].freeze

  def truncate_plan_tables
    truncate_tables(*PLAN_TABLES)
  end

  def truncate_tables(*tables)
    conn = ActiveRecord::Base.connection
    case conn.adapter_name
    when /mysql/i
      # Plain TRUNCATE refuses to touch FK-referenced tables regardless of
      # order, so FK checks go off for the duration.
      conn.execute("SET FOREIGN_KEY_CHECKS = 0")
      tables.each { |t| conn.execute("TRUNCATE TABLE #{t}") }
      conn.execute("SET FOREIGN_KEY_CHECKS = 1")
    when /postg/i
      conn.execute("TRUNCATE TABLE #{tables.join(', ')} CASCADE")
    else
      # e.g. SQLite, which has no TRUNCATE. DELETE respects FK order, so
      # callers list children before parents.
      tables.each { |t| conn.execute("DELETE FROM #{t}") }
    end
  end
end

RSpec.configure do |config|
  config.include TruncationHelpers
end
