import { Plugin, PluginKey } from "prosemirror-state"
import { Decoration, DecorationSet } from "prosemirror-view"
import { loadHljs, loadLanguage } from "coplan/syntax_highlight"

const key = new PluginKey("coplan-code-highlight")
const MAX_BLOCK = 20000, MAX_TOTAL = 100000

// Convert highlight.js's escaped token output to offsets in a detached tree.
// Only ProseMirror decorations may touch the live contentDOM.
function tokens(hljs, language, source) {
  const tree = document.createElement("div")
  tree.innerHTML = hljs.highlight(source, { language, ignoreIllegals: true }).value
  if (tree.textContent !== source) return []
  let offset = 0
  const result = []
  const walk = (node, classes) => {
    if (node.nodeType === Node.TEXT_NODE) {
      const end = offset + node.textContent.length
      if (end > offset && classes.length) result.push({ from: offset, to: end, classes: classes.join(" ") })
      offset = end
    } else {
      const inherited = [...classes, ...node.classList || []]
      node.childNodes.forEach(child => walk(child, inherited))
    }
  }
  walk(tree, [])
  return result
}

export function codeHighlight() {
  return new Plugin({
    key,
    state: {
      init: () => DecorationSet.empty,
      apply(tr, previous) {
        return tr.getMeta(key) || (tr.docChanged ? previous.map(tr.mapping, tr.doc) : previous)
      }
    },
    props: { decorations: state => key.getState(state) },
    view(view) {
      let timer, destroyed = false, generation = 0
      const cache = new Map(), unavailable = new Set()
      const schedule = () => {
        clearTimeout(timer)
        const sequence = ++generation
        timer = setTimeout(async () => {
          if (destroyed) return
          if (view.composing) { schedule(); return }
          const doc = view.state.doc, blocks = []
          let total = 0
          doc.descendants((node, position) => {
            if (node.type.name !== "code_block") return
            const language = (node.attrs.params || "").trim().split(/\s+/)[0].toLowerCase()
            if (!language || ["mermaid", "text", "txt", "plain", "plaintext"].includes(language) || node.content.size > MAX_BLOCK) return false
            total += node.content.size
            if (total <= MAX_TOTAL) blocks.push({ node, position, language })
            return false
          })
          const decorations = []
          try {
            const hljs = blocks.length ? await loadHljs() : null
            for (const { node, position, language } of blocks) {
              if (destroyed || sequence !== generation) return
              if (unavailable.has(language)) continue
              const name = await loadLanguage(hljs, language)
              if (!name) { unavailable.add(language); continue }
              const source = node.textContent, cacheKey = language + "\0" + source
              let spans = cache.get(cacheKey)
              if (!spans) {
                spans = tokens(hljs, name, source)
                if (cache.size >= 40) cache.delete(cache.keys().next().value)
                cache.set(cacheKey, spans)
              }
              for (const span of spans) decorations.push(Decoration.inline(position + 1 + span.from, position + 1 + span.to, { class: span.classes }))
            }
          } catch { /* Offline or unsupported grammar: source remains editable. */ }
          if (!destroyed && sequence === generation && view.state.doc === doc && !view.composing) {
            view.dispatch(view.state.tr.setMeta(key, DecorationSet.create(doc, decorations)).setMeta("addToHistory", false))
          } else if (!destroyed && sequence === generation) schedule()
        }, 100)
      }
      schedule()
      return {
        update(view, previous) { if (view.state.doc !== previous.doc) schedule() },
        destroy() { destroyed = true; generation++; clearTimeout(timer); cache.clear() }
      }
    }
  })
}
