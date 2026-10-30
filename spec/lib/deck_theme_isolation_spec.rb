require "rails_helper"

# A deck is a fixed artifact: app themes must not restyle its slides
# (docs/THEMES.md). This reads the stylesheets instead of rendering them, so
# a new theme variable fails here until deck.css resets it or the allowlist
# below says why the deck doesn't need it.
RSpec.describe "Deck isolation from app themes" do
  stylesheets = CoPlan::Engine.root.join("app/assets/stylesheets/coplan")

  # Prefixes and names a theme may set without a deck reset, with the reason.
  allowed = {
    "--color-" => "App tokens. In a deck they paint only the slide frame and the discussion controls around diagrams, which follow the app. Slide content reads --deck-* instead.",
    "--code-block-" => "`.deck pre` declares its own background, color, border, font-size and line-height.",
    "--diagram-" => "Mermaid reads the palette from the diagram's container, and `.deck` resets --diagram-bg, which turns the palette off on slides.",
    "--reading-" => "Reading type rules skip .deck-content.",
    "--plan-title-" => "App chrome outside slides.",
    "--document-" => "App chrome outside slides.",
    "--window-" => "App chrome outside slides.",
    "--panel-" => "App chrome outside slides.",
    "--overlay-" => "App chrome outside slides.",
    "--glass-" => "App chrome outside slides.",
    "--shadow-" => "App chrome outside slides.",
    "--page-backdrop" => "App chrome outside slides.",
    "--dialog-backdrop" => "App chrome outside slides.",
    "--composer-input-bg" => "App chrome outside slides.",
    "--surface-translucent" => "App chrome outside slides.",
    "--card-edge" => "App chrome outside slides."
  }

  declared = ->(css) { css.scan(/^\s*(--[\w-]+)\s*:/).flatten.uniq }
  block = lambda do |css, selector|
    css[/^#{Regexp.escape(selector)} \{\n(.*?)^\}/m, 1] or raise "#{selector} not found in deck.css"
  end

  deck_css = stylesheets.join("deck.css").read
  resets = declared.(block.(deck_css, ".deck")) + declared.(block.(deck_css, ".deck-slide .deck-content pre"))

  it "finds the deck's resets" do
    expect(resets).to include("--diagram-bg", "--strong-weight", "--code-label-bg", "--code-keyword")
  end

  Dir[stylesheets.join("themes/*.css")].sort.each do |path|
    it "resets or allowlists every variable #{File.basename(path)} sets" do
      leaks = declared.(File.read(path)).reject do |name|
        resets.include?(name) || allowed.keys.any? { |prefix| name.start_with?(prefix) }
      end

      expect(leaks).to be_empty,
        "Reset these in `.deck` or `.deck-slide .deck-content pre` in deck.css, " \
        "or add them to the allowlist in this spec with a reason: #{leaks.join(", ")}"
    end
  end
end
