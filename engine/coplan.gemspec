require_relative "lib/coplan/version"

Gem::Specification.new do |spec|
  spec.name        = "coplan-engine"
  spec.version     = CoPlan::VERSION
  spec.authors     = [ "Block" ]
  spec.summary     = "CoPlan — AI-assisted engineering design doc review"
  spec.description = "A Rails Engine for collaborative plan review with AI-powered feedback."
  spec.license     = "Apache-2.0"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib,prompts}/**/*", "Rakefile"]
  end

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "commonmarker"
  spec.add_dependency "diff-lcs"
  spec.add_dependency "diffy"
  spec.add_dependency "ruby-openai"
  spec.add_dependency "propshaft"
  spec.add_dependency "importmap-rails"
  spec.add_dependency "turbo-rails"
  spec.add_dependency "stimulus-rails"
  spec.add_dependency "jbuilder"
end
