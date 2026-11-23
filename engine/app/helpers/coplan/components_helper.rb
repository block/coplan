module Coplan
  module ComponentsHelper
    def render_component_region(region, version:, interactive:)
      title = region.attributes["title"].presence || region.attributes["type"]&.capitalize || "Component"
      catalog = version ? version.component_catalog : Coplan.configuration.component_catalog.snapshot([ region ])
      modules = ComponentCatalog.resolve(region.attributes, catalog) if catalog
      issue = modules&.fetch(:error, nil)
      enabled = Coplan.configuration.components_enabled && modules && !issue
      frame_data = if enabled
        { controller: "coplan--component", action: "message@window->coplan--component#ready coplan:theme-changed@window->coplan--component#syncTheme toggle->coplan--component#toggled turbo:before-cache@document->coplan--component#collapse",
          "coplan--component-url-value": coplan.component_frame_path,
          "coplan--component-program-value": modules.merge(source: region.source, title:, startLine: region.start_line).to_json }
      end
      render partial: "coplan/components/region", formats: [ :html ],
        locals: { region:, title:, enabled:, interactive:, issue:, frame_data: }
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
