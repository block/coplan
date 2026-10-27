require "commonmarker"
require "diffy"
require "openai"
require "coplan/configuration"
require "coplan/admin"
require "coplan/analytics"
require "coplan/engine"
require "coplan/exceptions_app"

module CoPlan
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end
  end
end
