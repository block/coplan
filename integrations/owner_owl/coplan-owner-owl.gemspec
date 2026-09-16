require_relative "lib/coplan/owner_owl/version"

Gem::Specification.new do |spec|
  spec.name = "coplan-owner-owl"
  spec.version = CoPlan::OwnerOwl::VERSION
  spec.authors = [ "Block" ]
  spec.summary = "Optional Owner Owl approval routing for CoPlan"
  spec.description = "Routes CoPlan approval requests from touched repository paths through Owner Owl's Ownership API."
  spec.homepage = "https://github.com/block/coplan"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*", "README.md"].select { |path| File.file?(path) } }
  spec.metadata["source_code_uri"] = "https://github.com/block/coplan/tree/main/integrations/owner_owl"

  spec.add_dependency "coplan-engine", ">= 0.4", "< 1"
end
