require "coplan/configuration"
require "coplan/user_model"
require "coplan/engine"

module CoPlan
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def user_class
      configuration.user_class.constantize
    end

    def user_class_name
      configuration.user_class
    end
  end
end
