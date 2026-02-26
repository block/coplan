module CoPlan
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
    self.table_name_prefix = "coplan_"

    before_create :assign_uuid, if: -> { id.blank? }

    private

    def assign_uuid
      self.id = SecureRandom.uuid_v7
    end
  end
end
