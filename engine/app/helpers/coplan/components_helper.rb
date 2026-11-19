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
            data: { component_comment_line: region.start_line, action: "coplan--source-comments#commentOnDiagram" })
        end
        if enabled
          actions << tag.button(component_icon(:expand), type: "button", title: "Expand component", aria: { label: "Expand component", expanded: false },
            data: { "coplan--component-target": "expand", action: "coplan--component#toggleExpanded" })
        end
        content = [ tag.figcaption(title), tag.div(safe_join(actions), class: "document-component__actions") ]
        content << tag.iframe("", sandbox: "allow-scripts", title:, referrerpolicy: "no-referrer",
          data: { "coplan--component-target": "frame" }) if enabled
        content << tag.p(issue, role: "status") if issue
        content << tag.details(open: !enabled, class: ("document-component__source" if enabled)) do
          summary = if enabled
            tag.summary(component_icon(:source), title: "View source", aria: { label: "View source" })
          else
            tag.summary("Source")
          end
          safe_join([ summary, tag.pre(tag.code(region.source)) ])
        end
        safe_join(content)
      end
    end

    private

    def component_icon(name)
      path = { comment: "M13.5 3.5h-11v8h3v2.5l3.5-2.5h4.5z", source: "m5.5 4.5-3.5 3.5 3.5 3.5m5-7L14 8l-3.5 3.5",
        expand: "M9.5 2.5h4v4M13.5 2.5 9 7M6.5 13.5h-4v-4M2.5 13.5 7 9" }.fetch(name)
      tag.svg(tag.path(d: path), viewBox: "0 0 16 16", width: 16, height: 16, fill: "none", stroke: "currentColor",
        "stroke-width": 1.5, "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": true)
    end
  end
end
