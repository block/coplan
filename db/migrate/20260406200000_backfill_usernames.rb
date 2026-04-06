class BackfillUsernames < ActiveRecord::Migration[8.1]
  def up
    CoPlan::User.where(username: nil).find_each do |user|
      base = user.external_id.to_s.split("@").first.downcase.gsub(/[^a-z0-9._-]/, "").sub(/\A[^a-z0-9]+/, "")
      base = base.presence || user.external_id.to_s.downcase.gsub(/[^a-z0-9._-]/, "").sub(/\A[^a-z0-9]+/, "")
      candidate = base
      counter = 1
      while CoPlan::User.where(username: candidate).where.not(id: user.id).exists?
        candidate = "#{base}#{counter}"
        counter += 1
      end
      user.update!(username: candidate)
    end
  end

  def down
    # no-op
  end
end
