pin "@rails/actioncable", to: "actioncable.esm.js"
pin "coplan/web_push", to: "coplan/web_push.js"
pin "mermaid", to: "https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.esm.min.mjs", preload: false
pin_all_from CoPlan::Engine.root.join("app/javascript/controllers/coplan"), under: "controllers/coplan", preload: true
