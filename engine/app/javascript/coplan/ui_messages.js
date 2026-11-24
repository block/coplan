let currentBody
let catalog
let pluralRules

// Rails sends the active page's client messages with its HTML. Turbo replaces
// the body on a visit, so a language change also replaces the message source.
export function t(key, values = {}) {
  if (currentBody !== document.body) {
    currentBody = document.body
    catalog = JSON.parse(currentBody?.dataset.coplanClientMessages || "{}")
    pluralRules = new Intl.PluralRules(document.documentElement.lang || "en")
  }
  const [, , group, name] = key.split(".")
  let message = catalog[group]?.[name]
  if (message && typeof message === "object") {
    message = message[pluralRules.select(values.count)] ?? message.other
  }
  if (typeof message !== "string") {
    console.warn("Missing Coplan UI message", key)
    return ""
  }
  return message.replace(/%\{(\w+)\}/g, (_, name) => String(values[name] ?? ""))
}
