import { loadHljs, loadLanguage } from "coplan/syntax_highlight"

// Region parsing has already identified the first and last lines as markers.
// Keep their spelling, optional metadata and line endings when editing a field.
function componentParts(source) {
  const separator = source.slice(0, source.indexOf("\n")).endsWith("\r") ? "\r\n" : "\n"
  const endHeader = source.indexOf("\n") + 1
  const closing = source.lastIndexOf("\n:::") + 1
  const header = source.slice(0, endHeader).trimEnd()
  const body = source.slice(endHeader, closing).replace(/^\r?\n/, "").replace(/\r?\n$/, "").replace(/\r?\n$/, "")
  const attributes = new Map(Array.from(header.matchAll(/ (type|uses|title)="([^"]*)"/g), match => [match[1], match]))
  return {
    header,
    body: body.replaceAll("\r\n", "\n"),
    type: attributes.get("type")?.[2] || "",
    libraries: attributes.get("uses")?.[2].split(/\s+/).filter(Boolean) || [],
    withBody(value) {
      return header + separator.repeat(2) + value.replaceAll("\n", separator) + separator.repeat(2) + source.slice(closing)
    },
    withAttribute(key, value) {
      const match = attributes.get(key)
      const start = match?.index ?? header.length - 1
      const attribute = value ? ` ${key}="${value}"` : ""
      return source.slice(0, start) + attribute + source.slice(start + (match?.[0].length || 0))
    }
  }
}

export function componentNodeView(node, getPos, preview, settled, catalog) {
  const dom = document.createElement("div")
  dom.className = "document-editor__block document-editor__component"
  dom.contentEditable = "false"
  dom.coplanPosition = getPos
  const header = document.createElement("div")
  header.className = "document-editor__block-header"
  const modes = document.createElement("div")
  modes.className = "document-editor__mode document-editor__component-mode"
  modes.setAttribute("role", "group")
  modes.setAttribute("aria-label", "Component view")
  header.append(modes)
  const buttons = ["Preview", "Edit"].map(label => {
    const button = document.createElement("button")
    button.type = "button"
    button.textContent = label
    button.dataset.componentView = label.toLowerCase()
    button.dataset.action = "coplan--editor#switchComponentView"
    modes.append(button)
    return button
  })
  const output = document.createElement("div")
  output.className = "document-editor__block-preview"
  const editor = document.createElement("div")
  const settings = document.createElement("div")
  settings.className = "document-editor__component-settings"
  const typeLabel = document.createElement("label")
  typeLabel.append("Type ")
  const type = document.createElement("select")
  type.dataset.action = "change->coplan--editor#componentFieldChanged"
  typeLabel.append(type)
  const moduleButton = document.createElement("button")
  moduleButton.type = "button"
  moduleButton.className = "document-editor__module-button"
  const libraries = document.createElement("div")
  libraries.className = "document-editor__module-picker"
  libraries.popover = "auto"
  libraries.setAttribute("role", "group")
  libraries.setAttribute("aria-label", "JavaScript modules")
  moduleButton.popoverTargetElement = libraries
  const help = document.createElement("button")
  help.type = "button"
  help.textContent = "Quick guide"
  help.className = "document-editor__component-help"
  help.dataset.action = "coplan--editor#openComponentGuide"
  help.setAttribute("aria-haspopup", "dialog")
  settings.append(typeLabel, help, moduleButton, libraries)
  header.prepend(settings)
  const script = document.createElement("textarea")
  script.className = "document-editor__block-source"
  script.spellcheck = false
  script.setAttribute("aria-label", "Component JavaScript")
  script.dataset.action = "input->coplan--editor#componentFieldChanged keydown->coplan--editor#blockKeydown"
  const sourceBox = document.createElement("div")
  sourceBox.className = "document-editor__component-code"
  const colors = document.createElement("div")
  colors.className = "document-editor__component-colors"
  colors.setAttribute("aria-hidden", "true")
  script.dataset.action += " scroll->coplan--editor#syncComponentColors compositionstart->coplan--editor#componentComposition compositionend->coplan--editor#componentComposition"
  sourceBox.append(colors, script)
  editor.append(sourceBox)
  dom.append(header, editor, output)

  // The textarea owns the caret, input method, selection, history and sizing.
  // Show its native text until a matching colored copy is ready.
  let highlighter, loading, timer, paintedSource, disposed = false, composing = false
  function syncColors() {
    colors.scrollTop = script.scrollTop
    colors.scrollLeft = script.scrollLeft
  }
  function schedulePaint() {
    clearTimeout(timer)
    const source = script.value
    const enabled = highlighter && !editor.hidden && !composing && source.length > 0 && source.length <= 20000
    const ready = enabled && paintedSource === source
    sourceBox.classList.toggle("is-colored", Boolean(ready))
    if (!enabled || ready) return
    timer = setTimeout(() => {
      try {
        colors.innerHTML = highlighter.highlight(source, { language: "javascript", ignoreIllegals: true }).value
        // A trailing newline in a textarea has its own editable line.
        colors.append("\u200b")
        paintedSource = source
        sourceBox.classList.add("is-colored")
        syncColors()
      } catch { paintedSource = null } // Native text stays visible.
    }, 80)
  }
  function openHighlighting() {
    if (!highlighter && !loading) {
      // A failed load can retry when Edit opens again.
      loading = loadHljs().then(async hljs => {
        if (await loadLanguage(hljs, "javascript") && !disposed) {
          highlighter = hljs
          schedulePaint()
        }
      }).catch(() => {}).finally(() => { loading = null })
    }
    schedulePaint()
  }
  dom.coplanSyncColors = syncColors
  dom.coplanCompose = active => { composing = active; schedulePaint() }
  const resize = new ResizeObserver(([entry]) => {
    // The fractional content box excludes the textarea's scrollbar and padding.
    colors.style.width = entry.contentRect.width + "px"
    colors.style.height = entry.contentRect.height + "px"
    syncColors()
  })
  resize.observe(script)

  let parts = componentParts(node.attrs.source)
  function syncSettings() {
    const types = new Set(["", ...Object.keys(catalog.types || {}), parts.type])
    for (const name of types) {
      if (![...type.options].some(option => option.value === name)) type.add(new Option(catalog.types?.[name]?.label || name || "Base", name))
    }
    type.value = parts.type
    help.hidden = !Object.hasOwn(catalog.types || {}, parts.type)
    help.dataset.componentType = parts.type
    const choices = new Set([...(catalog.libraries || []), ...parts.libraries])
    const typeModules = catalog.types?.[parts.type]?.uses
    if (Array.isArray(typeModules)) typeModules.forEach(name => choices.delete(name))
    moduleButton.hidden = choices.size === 0
    const selectedCount = parts.libraries.filter(name => choices.has(name)).length
    moduleButton.textContent = selectedCount ? `Modules (${selectedCount})` : "Modules"
    for (const input of libraries.querySelectorAll("input")) {
      if (!choices.has(input.value)) input.parentElement.remove()
    }
    for (const name of choices) {
      let input = [...libraries.querySelectorAll("input")].find(input => input.value === name)
      if (!input) {
        input = document.createElement("input")
        input.type = "checkbox"
        input.value = name
        input.dataset.action = "change->coplan--editor#componentFieldChanged"
        const label = document.createElement("label")
        label.append(input, document.createTextNode(name))
        libraries.append(label)
      }
      input.checked = parts.libraries.includes(name)
    }
  }
  dom.coplanComponentSource = field => {
    if (field === script) return parts.withBody(field.value)
    if (field === type) return parts.withAttribute("type", field.value)
    const selected = parts.libraries.filter(name => name !== field.value)
    if (field.checked) selected.push(field.value)
    return parts.withAttribute("uses", selected.join(" "))
  }

  let generation = 0, displayedSource = null
  async function render() {
    const source = node.attrs.source
    if (source === displayedSource) return
    displayedSource = null
    const request = ++generation
    output.textContent = "Loading preview…"
    try {
      if (!preview) throw new Error()
      const html = await preview(source)
      if (request !== generation) return
      output.innerHTML = html
      displayedSource = source
      settled(output)
    } catch {
      if (request === generation) output.textContent = "Preview unavailable. Choose Preview to retry."
    }
  }
  dom.coplanComponentView = mode => {
    const editing = mode === "edit"
    settings.hidden = !editing
    editor.hidden = !editing
    output.hidden = editing
    for (const button of buttons) button.setAttribute("aria-pressed", String(button.dataset.componentView === mode))
    if (editing) {
      generation++
      openHighlighting()
      script.focus({ preventScroll: true })
    } else {
      clearTimeout(timer)
      // An insertion switches to Edit in the same transaction. Only request
      // a preview if the reader will actually see it.
      queueMicrotask(() => { if (!disposed && !output.hidden) render() })
    }
  }
  script.value = parts.body
  syncSettings()
  dom.coplanComponentView("preview")
  return {
    dom,
    update(next) {
      if (next.type !== node.type || next.attrs.kind !== "component") return false
      if (node.attrs.source !== next.attrs.source) {
        node = next
        const previousHeader = parts.header
        parts = componentParts(node.attrs.source)
        if (script.value !== parts.body) script.value = parts.body
        schedulePaint()
        if (previousHeader !== parts.header) syncSettings()
        if (!output.hidden) render()
      }
      return true
    },
    stopEvent: () => true, ignoreMutation: () => true, destroy() { disposed = true; generation++; clearTimeout(timer); resize.disconnect() }
  }
}
