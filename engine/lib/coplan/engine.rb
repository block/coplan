module Coplan
  class Engine < ::Rails::Engine
    isolate_namespace Coplan

    config.after_initialize do
      Coplan::Themes.check_default!
      Coplan::UiLocale.check_configuration!
      Coplan::WritingProvenanceBackfillJob.start unless Rails.env.test? || ENV["SECRET_KEY_BASE_DUMMY"]
    end

    initializer "coplan.importmap", before: "importmap" do |app|
      app.config.importmap.paths << Engine.root.join("config/importmap.rb")
      app.config.importmap.cache_sweepers << Engine.root.join("app/javascript")
    end

    initializer "coplan.assets" do |app|
      app.config.assets.paths << Engine.root.join("app/assets/stylesheets")
      app.config.assets.paths << Engine.root.join("app/assets/images")
      app.config.assets.paths << Engine.root.join("app/javascript")
    end

    initializer "coplan.credential_filters" do |app|
      app.config.filter_parameters += [ :device_code, :user_code ]
    end

    initializer "coplan.factories", after: "factory_bot.set_factory_paths" do
      if defined?(FactoryBot)
        FactoryBot.definition_file_paths << Engine.root.join("spec", "factories")
      end
    end
  end
end
