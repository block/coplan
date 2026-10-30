module CoPlan
  # App themes. A theme is a named set of CSS variable values, applied with
  # <html data-ui-theme="key"> (docs/THEMES.md). Classic is the built-in look
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

    # The host's configured default. Falls back to Classic when the host
    # names a theme that doesn't exist.
    def self.default
      find(CoPlan.configuration.default_theme)&.key || CLASSIC
    end
  end
end
