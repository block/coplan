module CoPlan
  module ComponentsHelper
    def render_component_region(region, version:, interactive:)
      title = region.attributes["title"].presence || region.attributes["type"]&.capitalize || "Component"
      catalog = version ? version.component_catalog : CoPlan.configuration.component_catalog.snapshot([ region ])
      modules = ComponentCatalog.resolve(region.attributes, catalog) if catalog
      issue = modules&.fetch(:error, nil)
      enabled = CoPlan.configuration.components_enabled && modules && !issue
      data = if enabled
        { controller: "coplan--component", action: "message@window->coplan--component#ready",
          "coplan--component-url-value": coplan.component_frame_path,
          "coplan--component-program-value": modules.merge(source: region.source, title:, startLine: region.start_line).to_json }
      end
      tag.figure(class: "document-component", id: region.id, data: data || {}) do
        content = [ tag.figcaption(title) ]
        content << tag.iframe("", sandbox: "allow-scripts", title:, referrerpolicy: "no-referrer",
          data: { "coplan--component-target": "frame" }) if enabled
        content << tag.p(issue, role: "status") if issue
        content << tag.details(open: !enabled) do
          safe_join([ tag.summary("Source"), tag.pre(tag.code(region.source)) ])
        end
        if interactive
          content << tag.button("Comment", type: "button", class: "btn btn--secondary btn--small",
            data: { component_comment_line: region.start_line, action: "coplan--source-comments#commentOnDiagram" })
        end
        safe_join(content)
      end
    end
  end
end
