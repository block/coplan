require_relative "boot"

require "rails/all"

Bundler.require(*Rails.groups)

module CoPlan
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1
    config.exceptions_app = CoPlan::ExceptionsApp.new(Rails.root.join("public"))

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    config.generators do |g|
      g.orm :active_record, primary_key_type: :uuid
    end
  end
end
