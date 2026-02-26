module CoPlan
  class ApplicationPolicy
    attr_reader :user, :record

    def initialize(user, record)
      @user = user
      @record = record
    end

    def admin?
      user.can_admin_coplan?
    end
  end
end
