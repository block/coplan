pin "@rails/actioncable", to: "actioncable.esm.js"
pin "coplan/web_push", to: "coplan/web_push.js"
pin_all_from CoPlan::Engine.root.join("app/javascript/controllers/coplan"), under: "controllers/coplan", preload: true
