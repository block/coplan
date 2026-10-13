# CoPlan marks

The wordmark stays unchanged. The folded dialogue mark uses a different gradient for each environment:

| Environment | Palette | Vector source |
| --- | --- | --- |
| Production | Orchid Mesh: blue, violet, pink | `engine/app/assets/images/coplan/coplan-logo.svg` |
| Development | Emerald Mesh: mint, emerald, lime | `engine/app/assets/images/coplan/coplan-logo-development.svg` |
| Staging | Amber Mesh: gold, amber, coral | `engine/app/assets/images/coplan/coplan-logo-staging.svg` |

Navigation and SVG favicons share these sources. Each source also has a 192 × 192 transparent PNG export for favicon fallback, touch icons, and notification icons. Keep the PNG exports in sync when changing a source.

## Slack bot icon

Upload [coplan-slack-app-icon.png](coplan-slack-app-icon.png) in your Slack app's **Basic Information → Display Information → App icon**.

The image is a 1024 × 1024 PNG. It uses the production mark on CoPlan's dark background (`#0b1220`). The 768 × 768 mark is centered with 128 pixels of padding so the fold and dialogue tail survive avatar cropping. Slack supplies the outer crop; the file has no baked-in rounded corners.
