module CoPlan
  module Slack
    class Engine < ::Rails::Engine
      isolate_namespace CoPlan::Slack
    end
  end
end
