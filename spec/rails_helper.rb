require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods
  config.include ActiveSupport::Testing::TimeHelpers
  config.include CoPlan::Engine.routes.url_helpers



  def sign_in_as(coplan_user)
    host_user = User.find_or_create_by!(id: coplan_user.external_id) do |u|
      u.email = "#{coplan_user.external_id}@test.example.com"
      u.name = coplan_user.name
      u.role = coplan_user.admin? ? "admin" : "member"
    end
    post sign_in_path, params: { email: host_user.email }
  end
end
