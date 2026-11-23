module CoPlan
  module ComponentsHelper
    def render_component_region(region, version:, interactive:)
      title = region.attributes["title"].presence || region.attributes["type"]&.capitalize || "Component"
      catalog = version ? version.component_catalog : CoPlan.configuration.component_catalog.snapshot([ region ])
      modules = ComponentCatalog.resolve(region.attributes, catalog) if catalog
      issue = modules&.fetch(:error, nil)
      enabled = CoPlan.configuration.components_enabled && modules && !issue
      data = if enabled
        { controller: "coplan--component", action: "message@window->coplan--component#ready coplan:theme-changed@window->coplan--component#syncTheme toggle->coplan--component#toggled turbo:before-cache@document->coplan--component#collapse",
          "coplan--component-url-value": coplan.component_frame_path,
          "coplan--component-program-value": modules.merge(source: region.source, title:, startLine: region.start_line).to_json }
      end
      tag.figure(class: "document-component", id: region.id, data: data || {}) do
        actions = []
        if interactive
          actions << tag.button(component_icon(:comment), type: "button", title: "Comment on component", aria: { label: "Comment on component" },
            data: { component_comment_line: region.start_line, action: (enabled ? "click->coplan--component#annotate keydown.c->coplan--component#annotate:prevent" : "coplan--source-comments#commentOnDiagram") })
        end
        if interactive && enabled
          actions << tag.button("", type: "button", hidden: true, data: { component_discussions: "", action: "coplan--source-comments#componentDiscussions" })
        end
        if enabled
          actions << tag.button(component_icon(:expand), type: "button", title: "Expand component", aria: { label: "Expand component", expanded: false },
            data: { "coplan--component-target": "expand", action: "coplan--component#toggleExpanded" })
        end
        content = []
        content << tag.iframe("", sandbox: "allow-scripts", title:, referrerpolicy: "no-referrer",
          data: { "coplan--component-target": "frame" }) if enabled
        content << tag.p(issue, role: "status") if issue
        unless enabled
          content << tag.details(safe_join([ tag.summary("Source"), tag.pre(tag.code(region.source)) ]), open: true)
        end
        if interactive && enabled
          gestures = %w[pointerdown->coplan--component#start pointermove->coplan--component#move
                        pointerup->coplan--component#finish pointercancel->coplan--component#cancel keydown->coplan--component#key]
          content << tag.div(tag.span("", class: "document-component__mark"), hidden: true, tabindex: 0,
            role: "button", aria: { label: "Click or drag to annotate. Press Enter for the whole view or Escape to cancel." },
            class: "document-component__selection", data: { "coplan--component-target": "selection", action: gestures.join(" ") })
        end
        if actions.any?
          content << tag.div(class: "document-component__tab", tabindex: -1) do
            tag.div(safe_join(actions), class: "document-component__actions")
          end
        end
        safe_join(content)
      end
    end

    private

    def component_icon(name)
      path = { comment: "M13.5 3.5h-11v8h3v2.5l3.5-2.5h4.5z",
        expand: "M9.5 2.5h4v4M13.5 2.5 9 7M6.5 13.5h-4v-4M2.5 13.5 7 9" }.fetch(name)
      tag.svg(tag.path(d: path), viewBox: "0 0 16 16", width: 16, height: 16, fill: "none", stroke: "currentColor",
        "stroke-width": 1.5, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": true)
    end
  end
end
