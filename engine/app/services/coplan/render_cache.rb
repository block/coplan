require "digest"

module CoPlan
  # Rendered HTML belongs to the installed bundle, just as assets belong to
  # a build. A lockfile records Git revisions and all gem versions, including
  # the renderer's dependencies. No source scan or Git checkout is needed.
  class RenderCache
    def self.version
      return if Rails.application.config.reloading_enabled?

      @version ||= begin
        if defined?(Bundler) && Bundler.default_lockfile.file?
          # Path sources can change without changing the lockfile. Only an
          # explicit host release ID makes them safe to cache persistently.
          mutable = Bundler.locked_gems.sources.any? { |source| mutable_source?(source) }
          return if mutable && application_version.blank?

          Digest::SHA256.file(Bundler.default_lockfile).hexdigest
        else
          spec = Gem.loaded_specs.fetch("coplan-engine")
          return if spec.respond_to?(:source) && mutable_source?(spec.source) && application_version.blank?

          "coplan-engine-#{spec.version}"
        end
      end
    end

    def self.fetch(key, &block)
      return yield unless (release = version)

      # Use Rails' standard RAILS_CACHE_ID / RAILS_APP_VERSION prefix too.
      # The view cache helper already adds this prefix to fragment keys.
      Rails.cache.fetch(ActiveSupport::Cache.expand_cache_key([ "coplan/render", release, *key ]), &block)
    end

    def self.application_version
      ENV["RAILS_CACHE_ID"].presence || ENV["RAILS_APP_VERSION"].presence
    end
    private_class_method :application_version

    def self.mutable_source?(source)
      defined?(Bundler::Source::Path) && source.is_a?(Bundler::Source::Path) && !source.is_a?(Bundler::Source::Git)
    end
    private_class_method :mutable_source?
  end
end
