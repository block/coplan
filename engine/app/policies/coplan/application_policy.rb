module CoPlan
  class ApplicationPolicy
    attr_reader :user, :record

    def initialize(user, record)
      @user = user
      @record = record
    end

    def admin?
      user.admin?
    end
  end
end
