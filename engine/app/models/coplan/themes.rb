module CoPlan
  # App themes. A theme is a named set of CSS variable values, applied with
  # <html data-app-theme="key"> (docs/THEMES.md). Classic is the built-in look
  # and sets no variables. Light and dark are a separate choice, so every
  # theme comes in both.
  module Themes
    Theme = Data.define(:key, :name, :description)

    CLASSIC = "classic"

    ALL = [
      Theme.new(key: CLASSIC, name: "Classic", description: "Lexend, glass panels and the document card.")
    ].freeze

    def self.keys = ALL.map(&:key)

    def self.find(key) = ALL.find { |theme| theme.key == key.to_s }

    # The host's configured default theme. Falls back to Classic when the
    # host names a theme that doesn't exist.
    def self.default = find(CoPlan.configuration.default_theme) || find(CLASSIC)

    # Runs at boot, so a misspelled default doesn't fall back to Classic
    # unnoticed. Development and test raise; other environments log a
    # warning and keep serving Classic.
    def self.check_default!(env: Rails.env, logger: Rails.logger)
      name = CoPlan.configuration.default_theme
      return if find(name)

      message = "CoPlan config.default_theme is #{name.inspect}, which is not a theme. " \
        "Valid themes: #{keys.join(", ")}."
      raise ArgumentError, message if env.development? || env.test?
      logger.warn("#{message} Falling back to #{CLASSIC}.")
    end
  end
end
