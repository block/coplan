module CoPlan
  module KeyboardShortcutsHelper
    # Both the browser dispatcher and the server-rendered reference consume
    # this catalog. Read per request so development edits do not need a restart.
    def keyboard_shortcut_catalog
      @keyboard_shortcut_catalog ||= JSON.parse(CoPlan::Engine.root.join("config/keyboard_shortcuts.json").read)
    end

    def keyboard_shortcut_groups
      keyboard_shortcut_catalog.values.group_by { |scope| scope.fetch("group") }
    end

    def keyboard_shortcut_label(key)
      { "Mod" => "⌘ / Ctrl", " " => "Space", "Escape" => "Esc",
        "ArrowUp" => "↑", "ArrowDown" => "↓", "ArrowLeft" => "←", "ArrowRight" => "→",
        "PageUp" => "Page Up", "PageDown" => "Page Down" }.fetch(key, key)
    end
  end
end
