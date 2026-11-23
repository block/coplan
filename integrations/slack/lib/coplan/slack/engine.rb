module Coplan
  module Slack
    class Engine < ::Rails::Engine
      isolate_namespace Coplan::Slack
    end
  end
end
