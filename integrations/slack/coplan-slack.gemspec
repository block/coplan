require_relative "lib/coplan/slack/version"

Gem::Specification.new do |spec|
  spec.name = "coplan-slack"
  spec.version = CoPlan::Slack::VERSION
  spec.authors = [ "Block" ]
  spec.summary = "Optional Slack link previews for CoPlan"
  spec.description = "A Rails engine that adds Slack link unfurling to a CoPlan deployment."
  spec.homepage = "https://github.com/block/coplan"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir.chdir(__dir__) { Dir["{app,config,lib}/**/*", "README.md"] }
  spec.metadata["source_code_uri"] = "https://github.com/block/coplan/tree/main/integrations/slack"

  spec.add_dependency "coplan-engine", ">= 0.4", "< 1"
  spec.add_dependency "slack-ruby-client", "~> 3.0"
end
