module CoPlan
  class Engine < ::Rails::Engine
    isolate_namespace CoPlan

    initializer "coplan.autoloader", before: :set_autoload_paths do
      Rails.autoloaders.each do |autoloader|
        autoloader.inflector.inflect("coplan" => "CoPlan")
      end
    end

    initializer "coplan.importmap", before: "importmap" do |app|
      app.config.importmap.paths << Engine.root.join("config/importmap.rb")
      app.config.importmap.cache_sweepers << Engine.root.join("app/javascript")
    end

    initializer "coplan.assets" do |app|
      app.config.assets.paths << Engine.root.join("app/assets/stylesheets")
      app.config.assets.paths << Engine.root.join("app/javascript")
    end

    initializer "coplan.append_migrations", before: :load_config_initializers do |app|
      config.paths["db/migrate"].expanded.each do |path|
        app.config.paths["db/migrate"] << path
        ActiveRecord::Migrator.migrations_paths << path
      end
    end

    initializer "coplan.factories", after: "factory_bot.set_factory_paths" do
      if defined?(FactoryBot)
        FactoryBot.definition_file_paths << Engine.root.join("spec", "factories")
      end
    end

  end

  # Override table name prefix: isolate_namespace generates "co_plan_"
  # from CoPlan.underscore, but our tables use "coplan_"
  ActiveSupport.on_load(:active_record) do
    CoPlan.singleton_class.redefine_method(:table_name_prefix) { "coplan_" }
  end
end
