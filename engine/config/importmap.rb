pin "@rails/actioncable", to: "actioncable.esm.js"
pin "coplan/web_push", to: "coplan/web_push.js"
pin "coplan/deck_ink", to: "coplan/deck_ink.js"
# Statically imported by the mermaid and data-grid controllers, which are
# themselves preloaded — preload these too or every page pays a round trip
# to discover them.
pin "coplan/expander", to: "coplan/expander.js", preload: true
pin "coplan/pan_zoom", to: "coplan/pan_zoom.js", preload: true
pin "mermaid", to: "https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.esm.min.mjs", preload: false
pin_all_from CoPlan::Engine.root.join("app/javascript/controllers/coplan"), under: "controllers/coplan", preload: true
pin "prosemirror-model", to: "https://esm.sh/prosemirror-model@1.25.4?bundle&external=prosemirror-model,prosemirror-state,prosemirror-view,prosemirror-transform,prosemirror-commands,prosemirror-keymap,prosemirror-history,prosemirror-schema-list,prosemirror-markdown", preload: false
pin "prosemirror-state", to: "https://esm.sh/prosemirror-state@1.4.3?bundle&external=prosemirror-model,prosemirror-state,prosemirror-view,prosemirror-transform,prosemirror-commands,prosemirror-keymap,prosemirror-history,prosemirror-schema-list,prosemirror-markdown", preload: false
pin "prosemirror-view", to: "https://esm.sh/prosemirror-view@1.41.3?bundle&external=prosemirror-model,prosemirror-state,prosemirror-view,prosemirror-transform,prosemirror-commands,prosemirror-keymap,prosemirror-history,prosemirror-schema-list,prosemirror-markdown", preload: false
pin "prosemirror-transform", to: "https://esm.sh/prosemirror-transform@1.10.5?bundle&external=prosemirror-model,prosemirror-state,prosemirror-view,prosemirror-transform,prosemirror-commands,prosemirror-keymap,prosemirror-history,prosemirror-schema-list,prosemirror-markdown", preload: false
pin "prosemirror-commands", to: "https://esm.sh/prosemirror-commands@1.7.1?bundle&external=prosemirror-model,prosemirror-state,prosemirror-view,prosemirror-transform,prosemirror-commands,prosemirror-keymap,prosemirror-history,prosemirror-schema-list,prosemirror-markdown", preload: false
pin "prosemirror-keymap", to: "https://esm.sh/prosemirror-keymap@1.2.3?bundle&external=prosemirror-model,prosemirror-state,prosemirror-view,prosemirror-transform,prosemirror-commands,prosemirror-keymap,prosemirror-history,prosemirror-schema-list,prosemirror-markdown", preload: false
pin "prosemirror-history", to: "https://esm.sh/prosemirror-history@1.4.1?bundle&external=prosemirror-model,prosemirror-state,prosemirror-view,prosemirror-transform,prosemirror-commands,prosemirror-keymap,prosemirror-history,prosemirror-schema-list,prosemirror-markdown", preload: false
pin "prosemirror-schema-list", to: "https://esm.sh/prosemirror-schema-list@1.5.1?bundle&external=prosemirror-model,prosemirror-state,prosemirror-view,prosemirror-transform,prosemirror-commands,prosemirror-keymap,prosemirror-history,prosemirror-schema-list,prosemirror-markdown", preload: false
pin "prosemirror-markdown", to: "https://esm.sh/prosemirror-markdown@1.13.2?bundle&external=prosemirror-model,prosemirror-state,prosemirror-view,prosemirror-transform,prosemirror-commands,prosemirror-keymap,prosemirror-history,prosemirror-schema-list,prosemirror-markdown", preload: false
pin "coplan/rich_document", to: "coplan/rich_document.js", preload: false
pin "diff", to: "https://esm.sh/diff@8.0.2?bundle", preload: false
pin "coplan/merge_text", to: "coplan/merge_text.js", preload: false

pin "coplan/syntax_highlight", to: "coplan/syntax_highlight.js", preload: false
pin "coplan/code_highlight", to: "coplan/code_highlight.js", preload: false
