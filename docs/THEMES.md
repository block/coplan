# App themes

A theme changes how CoPlan looks, never what it does. It is a named set of
CSS variable values. Light and dark mode are a separate choice, so a theme
defines both.

## Terms

| Term | Means | In code |
| --- | --- | --- |
| Mode | Light, dark or system | `data-theme`, `theme_preference`, `theme_controller.js`. These names predate app themes and stay. |
| Theme | The app's look: Classic, … | `data-app-theme`, `CoPlan::Themes`, `config.default_theme` |
| Deck theme | A slide look: `coplan`, `graphite` | the `theme` attribute on a presentation region. Always say "deck theme". |

If the mode attribute is ever renamed, move `data-theme` to `data-mode` and
accept both for a release, since host CSS may target it.

Classic is the built-in look: Lexend, glass panels and the document card. It
sets no variables. Every rule that a theme can change reads a variable with
Classic's value as the fallback, `var(--hook, <Classic value>)`. A theme sets
only the hooks it changes.

## How a theme is applied

The layout renders `<html data-app-theme="classic">`. The value is the host's
`config.default_theme` (see [HOST_APP_GUIDE.md](HOST_APP_GUIDE.md)), and
falls back to `classic` for an unknown name. Light and dark stay on
`data-theme`.

The themes are listed in `CoPlan::Themes::ALL`
(`engine/app/models/coplan/themes.rb`).

## Adding a theme

1. Add an entry to `CoPlan::Themes::ALL`.
2. Add `engine/app/assets/stylesheets/coplan/themes/<key>.css` and import it
   last in `coplan/application.css`.
3. Set tokens and hooks under `:root[data-app-theme="<key>"]`. For dark mode,
   repeat them under `:root[data-app-theme="<key>"][data-theme="dark"]` and
   inside `@media (prefers-color-scheme: dark)` under
   `:root[data-app-theme="<key>"]:not([data-theme])`.
4. Set custom properties only. A hook can also be set on a component, for
   example `:root[data-app-theme="<key>"] .plan-document { --color-surface: … }`.

A hook set on `:root` resolves any `var()` it uses at the root. To follow a
token that changes further down the page, set the hook on that component.

Decks are fixed artifacts. `.deck` sets every document hook to `initial`,
which brings back the built-in value, so themes never restyle slides.

## Tokens

Every token in `foundation.css` `:root` can be overridden, for example
`--color-bg`, `--color-text`, `--font-sans`, `--font-mono`,
`--code-block-bg`, the `--code-*` syntax colors, `--glass-*` and
`--shadow-*`. Keep blue for interaction and orange for attention
([DESIGN.md](DESIGN.md)).

## Hooks

| Area | Hooks |
| --- | --- |
| Page | `--page-backdrop` (the body's background image) |
| Glass | `--glass-blur` (panels), `--window-blur` (comment window, review tray, voice button), `--overlay-blur` (modal backdrops) |
| Floating windows | `--window-bg`, `--window-edge`, `--window-shadow`, `--composer-input-bg` |
| Overlays | `--overlay-tint` (new-document and expanded views), `--dialog-backdrop` (review dialog) |
| Panels | `--panel-bg`, `--panel-edge`, `--panel-shadow`, `--panel-row-bg`, `--document-support-radius` |
| Document card | `--document-bg`, `--document-border`, `--document-radius`, `--document-shadow`, `--document-padding`, `--document-padding-narrow` (phones) |
| Plan title | `--plan-title-size`, `--plan-title-size-narrow`, `--plan-title-weight`, `--plan-title-leading`, `--plan-title-tracking`, `--plan-title-wrap` |
| Reading type | `--reading-measure`, `--reading-leading`, `--reading-paragraph-gap`, `--reading-heading-weight`, `--reading-heading-tracking`, `--reading-heading-wrap`, `--reading-h1-size`, `--reading-h1-leading`, and for h2 and h3: `-size`, `-leading`, `-space-above`, `-space-below` |
| Emphasis | `--strong-weight` |
| Code blocks | `--code-block-border`, `--code-block-radius`, `--code-block-padding`, `--code-block-font-size`, `--code-block-leading`, `--code-block-scrollbar` |
| Code label | `--code-label-height`, `--code-label-margin`, `--code-label-padding`, `--code-label-bg`, `--code-label-dots`, `--code-label-border`, `--code-label-radius`, `--code-label-font`, `--code-label-leading`, `--code-label-tracking`, `--code-label-align` |
| Inline code | `--code-chip-padding`, `--code-chip-radius`, `--code-chip-size` |
| Diagrams | `--diagram-bg`, `--diagram-border`, `--diagram-radius` |
| Tables | `--table-radius`, `--table-numerals` |
| Other | `--blockquote-rule`, `--image-outline` |

Reading type applies to the document body in the reader and the editor
only. Comments, previews and decks keep their own type.

## Diagram palette

A theme can give Mermaid diagrams its own colors. Set all of these as hex
values (Mermaid's color math can't read `oklch()`), per scheme:
`--diagram-bg`, `--diagram-node`, `--diagram-node-border`, `--diagram-text`,
`--diagram-line`, `--diagram-cluster`, `--diagram-cluster-border`,
`--diagram-actor-line`, `--diagram-alt`, `--diagram-note`,
`--diagram-note-border`, `--diagram-note-text`.

If any of them is missing, documents keep Mermaid's built-in themes. Decks
always do.
