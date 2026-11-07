# Independent checks share the same worker budget as the RSpec shards.
LOCAL_CI_CHECKS = {
  "rubocop" => [ "bin/rubocop", "--no-parallel" ],
  "gem-audit" => [ "bin/bundler-audit" ],
  "importmap-audit" => [ "bin/importmap", "audit" ],
  "brakeman" => [ "bin/brakeman", "--quiet", "--no-pager", "--exit-on-warn", "--exit-on-error" ]
}.freeze
