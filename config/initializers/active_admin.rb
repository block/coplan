ActiveAdmin.setup do |config|
  config.comments = false
  config.batch_actions = true
  config.filter_attributes = []
  config.localize_format = :long

  CoPlan::Admin.install!(config)
end
