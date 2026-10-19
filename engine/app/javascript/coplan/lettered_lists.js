const letteredMarker = /^((?:[ \t]*>[ \t]?)*[ \t]*)([A-Z]{1,9}|[a-z]{1,9})\)(?=[ \t\r]|$)/
const numberedMarker = /^(?:[ \t]*>[ \t]?)*[ \t]*(\d{1,9})[.)](?=[ \t\r]|$)/

export function letterOrder(letters) {
  return [...letters.toUpperCase()].reduce((value, char) => value * 26 + char.charCodeAt(0) - 64, 0)
}

export function letterMarker(order, style) {
  let letters = ""
  for (let value = order; value > 0; value = Math.floor((value - 1) / 26))
    letters = String.fromCharCode(65 + (value - 1) % 26) + letters
  return style === "lower-alpha" ? letters.toLowerCase() : letters
}

function copyToken(token) {
  const copy = Object.assign(new token.constructor(token.type, token.tag, token.nesting), token)
  copy.attrs = token.attrs?.map(attribute => [...attribute]) || null
  return copy
}

// Split adjacent ordered lists when their marker style changes. Both parsers
// use byte-for-byte marker replacements so source ranges remain unchanged.
function styledLists(tokens, markers, lines) {
  const output = []
  for (let index = 0; index < tokens.length; index++) {
    const open = tokens[index]
    if (open.type !== "ordered_list_open") { output.push(open); continue }
    const end = tokens.findIndex((token, at) => at > index && token.type === "ordered_list_close" && token.level === open.level)
    const groups = []
    for (let item = index + 1; item < end;) {
      const start = tokens[item]
      const close = tokens.findIndex((token, at) => at > item && token.type === "list_item_close" && token.level === start.level)
      const marker = markers.get(start.map[0]) || { style: null, order: +(numberedMarker.exec(lines[start.map[0]])?.[1] || 1) }
      if (!groups.length || groups.at(-1).style !== marker.style) groups.push({ ...marker, tokens: [], from: start.map[0] })
      groups.at(-1).tokens.push(...styledLists(tokens.slice(item, close + 1), markers, lines))
      groups.at(-1).to = start.map[1]
      item = close + 1
    }
    for (const group of groups) {
      const start = copyToken(open)
      start.attrSet("start", group.order)
      start.meta = { ...open.meta, listStyle: group.style }
      start.map = [group.from, group.to]
      output.push(start, ...group.tokens, copyToken(tokens[end]))
    }
    index = end
  }
  return output
}

export function enableLetteredLists(tokenizer) {
  const parse = tokenizer.parse.bind(tokenizer)
  // The editor disables HTML, but its contents must still keep their literal
  // source. Recognize complete HTML blocks before converting any markers.
  const protectionParser = new tokenizer.constructor("commonmark", { html: true })
  tokenizer.parse = (source, environment = {}) => {
    const initial = parse(source, environment)
    const lines = source.split("\n")
    if (!lines.some(line => letteredMarker.test(line))) return initial
    const protectedLines = new Set()
    for (const token of initial) {
      if (token.type === "preserved_block" && token.meta?.kind === "table")
        for (let line = token.map[0]; line < token.map[1]; line++) protectedLines.add(line)
    }
    const candidate = lines.map(line => line.replace(letteredMarker,
      (_, prefix, letters) => `${prefix}${"1".padStart(letters.length, "0")})`)).join("\n")
    for (const token of protectionParser.parse(candidate, {})) {
      if (!token.map) continue
      if (!["fence", "code_block", "html_block"].includes(token.type)) continue
      for (let line = token.map[0]; line < token.map[1]; line++) protectedLines.add(line)
    }
    const markers = new Map()
    const normalized = lines.map((line, index) => {
      const match = letteredMarker.exec(line)
      if (!match || protectedLines.has(index)) return line
      const letters = match[2]
      markers.set(index, { style: letters === letters.toUpperCase() ? "upper-alpha" : "lower-alpha", order: letterOrder(letters) })
      return line.replace(letteredMarker, `${match[1]}${"1".padStart(letters.length, "0")})`)
    }).join("\n")
    return markers.size ? styledLists(parse(normalized, environment), markers, lines) : initial
  }
}
