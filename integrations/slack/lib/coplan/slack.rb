require "slack-ruby-client"
require "coplan"
require "coplan/slack/version"
require "coplan/slack/configuration"
require "coplan/slack/engine"

module CoPlan
  module Slack
    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
      end
    end
  end
end
