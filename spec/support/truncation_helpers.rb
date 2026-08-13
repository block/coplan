# Adapter-portable TRUNCATE for the search specs, which run without
# transactional fixtures (InnoDB FULLTEXT writes are invisible to
# MATCH … AGAINST inside the same transaction) and so must clean up manually.
module TruncationHelpers
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
