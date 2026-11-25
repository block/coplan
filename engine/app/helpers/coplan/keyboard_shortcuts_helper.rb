module Coplan
  module KeyboardShortcutsHelper
    # Both the browser dispatcher and the server-rendered reference consume
    # this catalog. Read per request so development edits do not need a restart.
    def keyboard_shortcut_catalog
      @keyboard_shortcut_catalog ||= JSON.parse(Coplan::Engine.root.join("config/keyboard_shortcuts.json").read)
    end

    def keyboard_shortcut_groups
      labels = I18n.t("coplan.keyboard_shortcuts")
      keyboard_shortcut_catalog.each_with_object({}) do |(id, scope), groups|
        group = labels.fetch(:groups).fetch(scope.fetch("group").to_sym)
        descriptions = labels.fetch(:bindings).fetch(id.to_sym)
        bindings = scope.fetch("bindings").map do |binding|
          binding.merge("description" => descriptions.fetch(binding.fetch("id").to_sym))
        end
        (groups[group] ||= []).concat(bindings)
      end
    end

    def keyboard_shortcut_label(key)
      { "Mod" => "⌘ / Ctrl", " " => I18n.t("coplan.shared.messages.space"), "Escape" => "Esc",
        "ArrowUp" => "↑", "ArrowDown" => "↓", "ArrowLeft" => "←", "ArrowRight" => "→",
        "PageUp" => I18n.t("coplan.shared.messages.page_up"), "PageDown" => I18n.t("coplan.shared.messages.page_down") }.fetch(key, key)
    end
  end
end
