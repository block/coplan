# App themes

A theme changes how Coplan looks, never what it does. It is a named set of
CSS variable values. Light and dark mode are a separate choice, so a theme
defines both.

## Terms

| Term | Means | In code |
| --- | --- | --- |
| Mode | Light, dark or system | `data-theme`, `theme_preference`, `theme_controller.js`. These names predate app themes and stay. |
| Theme | The app's look: Classic or Neutral | `data-app-theme`, `CoPlan::Themes`, `config.default_theme` |
| Deck theme | A slide look: `coplan`, `graphite` | the `theme` attribute on a presentation region. Always say "deck theme". |

If the mode attribute is ever renamed, move `data-theme` to `data-mode` and
accept both for a release, since host CSS may target it.

Classic is the built-in look: Lexend, glass panels and the document card. It
sets no variables. Every rule that a theme can change reads a variable with
Classic's value as the fallback, `var(--hook, <Classic value>)`. A theme sets
only the hooks it changes.

Neutral is for reading: warm grays, the system font, no glass or page
backdrop, and the document set flat on the page. Its headings keep the shared
size scale. It lives in `themes/neutral.css`.

## How a theme is applied

The layout renders `<html data-app-theme="classic">`
(`ApplicationHelper#coplan_app_theme`). Light and dark stay on `data-theme`.

The value is the viewer's own pick, if they made one. Each person chooses
under Settings → Appearance → Theme, stored in `coplan_users.app_theme`. Its
values are `default` or a theme key. `default`, the column default, follows
the host's `config.default_theme` (see [HOST_APP_GUIDE.md](HOST_APP_GUIDE.md)),
so a host can change the look for everyone who hasn't chosen. A stored key
that is no longer a theme falls back to that default. An unknown
`config.default_theme` stops boot in development and test. In other
environments it logs a warning and falls back to `classic`.

Picking a theme applies at once, without a reload (`app_theme_controller.js`):
it sets `data-app-theme`, dispatches `coplan:theme-changed` on `window`, and
saves with `PATCH /settings/app_theme` in the background. Saves from every
control on the page go out one at a time, in the order they were picked. The
stored choice, `default` or a theme key, is on `<html data-app-theme-choice>`
and updates when a save lands. If the save fails, that choice comes back.
Code that reads theme values in JavaScript, such as the Mermaid palette,
should redraw on `coplan:theme-changed`.

The Appearance button in the top bar, beside notifications, offers the same
choices from any page (`shared/_appearance_menu.html.erb`): the mode, and
Classic or Neutral with the theme that's showing checked. It has no Default
option; Settings keeps that. The menu and Settings use the same controllers
and keep each other's radios in step (`coplan:app-theme`).

The themes are listed in `CoPlan::Themes::ALL`
(`engine/app/models/coplan/themes.rb`).

## Adding a theme

1. Add an entry to `CoPlan::Themes::ALL`.
2. Add `engine/app/assets/stylesheets/coplan/themes/<key>.css` and import it
   last in `coplan/application.css`.
3. Set tokens and hooks under `:root[data-app-theme="<key>"]`. Give each
   color its light and dark value with `light-dark(<light>, <dark>)`, which
   follows the mode, including inside borders and shadows. Give a shadow the
   same layers in both modes and use `transparent` for a layer one mode
   doesn't have. The diagram palette is the exception (below).
4. Set custom properties only, so a theme changes how Coplan looks, never
   what it does. A hook can also be set on a component, for example
   `:root[data-app-theme="<key>"] .plan-document { --color-surface: … }`.
   Anything a theme would solve with a rule, such as an opening H1 that
   repeats the plan title, belongs to every theme, in shared CSS or markup.

A hook set on `:root` resolves any `var()` it uses at the root. To follow a
token that changes further down the page, set the hook on that component.

Decks are fixed artifacts. `.deck` sets every document hook to `initial`,
which brings back the built-in value, so themes never restyle slides. Code
panels on slides pin their own colors in `.deck-slide .deck-content pre`.
`spec/lib/deck_theme_isolation_spec.rb` checks that every variable a theme
file sets is reset there or allowlisted with a reason. Decks also set
`--font-sans` and `--font-mono` back to the built-in stacks,
`--font-builtin-sans` and `--font-builtin-mono`, so diagram labels and code
inside a slide keep the deck's fonts. Themes don't set those two. Mermaid
reads its label font and its palette from the diagram's container, not the
page.

## Tokens

Every token in `foundation.css` `:root` can be overridden, for example
`--color-bg`, `--color-text`, `--font-sans`, `--font-mono`,
`--code-block-bg`, the `--code-*` syntax colors, `--glass-*` and
`--shadow-*`. Keep blue for interaction and orange for attention
([DESIGN.md](DESIGN.md)).

Shadows mix heights. `--shadow-glass` is on cards and pills on the page and
also on menus and dialogs. `--shadow-pop` is on buttons and hover lifts.
`--shadow-lg` is on thread windows and other popovers. To keep page cards
flat while menus float, set a quiet `--shadow-glass` on `:root` and set it
again on the floating panels. Neutral shows how.

## Hooks

| Area | Hooks |
| --- | --- |
| Page | `--page-backdrop` (the body's background image) |
| Glass | `--glass-blur` (panels), `--window-blur` (comment window, review tray, voice button), `--overlay-blur` (modal backdrops) |
| Floating windows | `--window-bg`, `--window-edge`, `--window-shadow`, `--composer-input-bg` |
| Overlays | `--overlay-tint` (new-document and expanded views), `--dialog-backdrop` (review dialog) |
| Panels | `--panel-bg`, `--panel-edge`, `--panel-shadow`, `--panel-row-bg`, `--document-support-radius` |
| Document card | `--document-bg`, `--document-border`, `--document-radius`, `--document-shadow`, `--document-padding`, `--document-padding-narrow` (phones), `--document-page-padding-narrow` (phone page gutter around both the masthead and document; cardless themes need room for the 22px update target) |
| Plan title | `--plan-title-size`, `--plan-title-size-narrow`, `--plan-title-weight`, `--plan-title-leading`, `--plan-title-tracking`, `--plan-title-wrap` |
| Reading type | `--reading-measure`, `--reading-leading`, `--reading-paragraph-gap`, `--reading-heading-weight`, `--reading-heading-tracking`, `--reading-heading-wrap`, `--reading-h1-size`, `--reading-h1-leading`, and for h2 and h3: `-size`, `-leading`, `-space-above`, `-space-below`; `--reading-h4-weight` (defaults to the heading weight) |
| Emphasis | `--strong-weight` |
| Code blocks | `--code-block-text`, `--code-block-border`, `--code-block-radius`, `--code-block-padding`, `--code-block-font-size`, `--code-block-leading`, `--code-block-scrollbar` |
| Code label | `--code-label-height`, `--code-label-margin`, `--code-label-padding`, `--code-label-bg`, `--code-label-dots`, `--code-label-border`, `--code-label-radius`, `--code-label-font`, `--code-label-leading`, `--code-label-tracking`, `--code-label-align` |
| Inline code | `--code-chip-padding`, `--code-chip-radius`, `--code-chip-size` |
| Diagrams | `--diagram-bg`, `--diagram-border`, `--diagram-radius` |
| Tables | `--table-radius`, `--table-numerals` |
| Images | `--image-outline`, `--image-radius` |
| Other | `--blockquote-rule` |

Reading type applies to the document body in the reader and the editor
only. Comments, previews and decks keep their own type.

## Diagram palette

A theme can give Mermaid diagrams its own colors. Set all of these as hex
values (Mermaid's color math can't read `oklch()`). Mermaid reads them with
`getComputedStyle`, which returns `light-dark()` unresolved, so set the dark
values in a block under `:root[data-app-theme="<key>"][data-theme="dark"]` and
one inside `@media (prefers-color-scheme: dark)` under
`:root[data-app-theme="<key>"]:not([data-theme])`:
`--diagram-bg`, `--diagram-node`, `--diagram-node-border`, `--diagram-text`,
`--diagram-line`, `--diagram-cluster`, `--diagram-cluster-border`,
`--diagram-actor-line`, `--diagram-alt`, `--diagram-note`,
`--diagram-note-border`, `--diagram-note-text`.

Each diagram reads the palette from its own container. If any of them is
missing there, the diagram uses Mermaid's built-in themes. `.deck` sets them
all to `initial`, so slides always do. An expanded deck diagram keeps the
slide's background, so its built-in colors stay readable in either mode.
