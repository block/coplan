# Internationalization

Coplan keeps interface copy in Rails I18n. English is the source language
and the default. The engine ships English and Spanish for the browser
interface. The example host enables both. Each host can choose its enabled
locales and configure the fallback.

## Change copy

1. Find the view, controller, or Stimulus behavior where the person reads
   the message. Pick a semantic key under `coplan.<surface>` and add it to
   `engine/config/locales/<surface>.en.yml` and its counterpart for each
   other catalog language. Use the same PR for English and translations.
2. Agents can draft the translations as part of implementing the feature.
   Give them the full sentence, the surrounding UI, and what the action
   does. Read the translations in context and keep terminology consistent.
   In Spanish, use clear, region-neutral wording and address the reader
   consistently. Use “plan” for a Coplan plan and “persona” for a person
   found in search.
3. Use Rails `t` for text and `l` for dates and times. Translate complete
   messages, including accessible names, errors, empty and loading states,
   and confirmations. Pass variables by name and plurals with `count:`.
   Rails and the locale determine plural forms and word order. Keep HTML
   and URLs in templates and use ordinary escaped output.
4. Keep persisted state identifiers, routes, analytics names, API codes,
   and agent instructions stable. Translate interface labels for state
   identifiers at render time. Display authored plan and comment text as
   supplied.

```erb
<%= t("coplan.search.no_matches", query: query) %>
<%= t("coplan.search.result_count", count: result_count) %>
```

For a controller that needs one or two messages, render them as Stimulus
values on its element. Use server-rendered results for live announcements
when the result already includes the right text.

```erb
<div data-controller="coplan--search"
     data-coplan--search-searching-value="<%= t("coplan.search.searching") %>">
```

```js
static values = { searching: String }

this.announcementTarget.textContent = this.searchingValue
```

For interactions with several messages, add literal keys under
`coplan.client.<feature>`. Declare the feature with
`use_coplan_client_messages(:feature)` in the full-page view that hosts the
controller. Rails sends the active language's messages for that page with
the HTML. Import `t` from `coplan/ui_messages` and pass named interpolation
values. Use a stable identifier for behavior and use `textContent` for
the translated text.

```js
import { t } from "coplan/ui_messages"

this.noticeTarget.textContent = t("coplan.client.editor.saved_version", { revision })
```

For browser-only dates and plurals, use the document language with `Intl`.
For a translated sentence that contains a link or other markup, use a Rails
`_html` key with a named placeholder. Build and escape the markup with Rails
helpers in the view. Catalog values stay plain text.

## Check a change

```sh
bundle exec i18n-tasks normalize
bin/i18n-lint
```

The lint job checks translation usage, missing keys, interpolation
variables, normalization, duplicate keys, and plain-text catalog values.
Use literal keys where practical so the scanner can follow them. If keys
genuinely depend on data, document the finite set at the call site and
configure a narrow scanner exception if needed. The lint job checks
structure. The PR review checks meaning. When adding a language, add it
to `locales` in `config/i18n-tasks.yml` so CI checks it on every PR.

Run `bin/dev`. Sign in as `hampton@example.com`, open `/_/settings`,
and choose **Español** or **English** under **Language**. The selection takes
effect immediately and applies to that browser session. Choose **Browser
language** to use your browser's preferences again.

Exercise the affected journey in both languages. Include a few representative
screenshots in the PR for multilingual changes, especially when longer
strings or narrow screens might affect the layout. Check light and dark mode
and the relevant focus, error, and empty states.

Codex reads the repository's [review rules](../AGENTS.md#internationalization).
For each PR, review changes to English, translations, and the UI that gives
them context. Compare each affected translation with the English meaning,
including unchanged translations affected by a source edit. Flag offensive
or discriminatory text, deceptive wording, hidden content, and changes to
the action or outcome. Escalate uncertain meaning to a fluent reviewer.
The existing [PR stewardship workflow](PR_STEWARDSHIP.md#2-request-automated-reviews)
requests Codex when a review is needed. Repository admins can select
**All PRs** for automatic code review in the Codex GitHub settings.
[Codex GitHub integration](https://developers.openai.com/codex/integrations/github)

## Runtime

- Rails loads catalogs into its normal in-memory backend. Warm page rendering
  looks up the messages that page uses. Catalog size mainly affects loading
  time and process memory. An English-only host skips header negotiation.
- HTML, Turbo Streams, and browser JSON declare their content language.
  Multi-language hosts vary localized responses by `Accept-Language` and
  `Cookie`. Keep personalized responses private. Include the locale in an
  ETag or fragment key when output differs. The document body and comment
  caches share ordinary Markdown across languages and vary for translated
  rendering such as task labels, citations, or presentation controls.
- Stimulus reads messages from the page. Switching languages replaces the
  page through Turbo, so the browser gets the next language's messages with
  the rest of the UI. Normal interactions make no translation requests.
- Plan pages keep a shared Turbo stream for locale-neutral updates. When a
  broadcast contains translated HTML, each viewer subscribes to one extra
  stream for their language. The server renders those fragments once per
  enabled locale and shares the result among viewers in that locale. Single
  language hosts keep one stream and one render. Presence keeps its existing
  change detection. Review actions that already request viewer-specific
  controls continue to use that request.
- Use ordinary Rails and Hotwire checks as the catalog grows. Compare warm
  HTML and Turbo Frame requests on the same data if a change touches a hot
  path. Look at response bytes, render time, queries, and process memory. Run
  a small number of end-to-end checks on translated features and verify a
  shared discussion with one reader in each language when changing live
  updates. Before adding an RTL locale, check direction, mixed-direction
  content, and keyboard behavior.
