require "commonmarker"
require "diffy"
require "openai"
require "coplan/configuration"
require "coplan/analytics"
require "coplan/engine"

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
