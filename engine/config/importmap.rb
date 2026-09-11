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
