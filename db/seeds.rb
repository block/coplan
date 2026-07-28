if Rails.env.local?
  require_relative "seeds/development"
  CoPlan::DevelopmentSeed.call
else
  warn "Development seed data is only available in development and test environments."
end
