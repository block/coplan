ActiveAdmin.setup do |config|
  config.comments = false
  config.batch_actions = true
  config.filter_attributes = []
  config.localize_format = :long

  Coplan::Admin.install!(config)
end
