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
  settings.append(typeLabel, moduleButton, libraries)
  if (catalog.guide) {
    const help = document.createElement("a")
    help.href = catalog.guide
    help.target = "_blank"
    help.rel = "noopener"
    help.textContent = "Component guide ↗"
    settings.append(help)
  }
  const script = document.createElement("textarea")
  script.className = "document-editor__block-source"
  script.spellcheck = false
  script.setAttribute("aria-label", "Component JavaScript")
  script.dataset.action = "input->coplan--editor#componentFieldChanged keydown->coplan--editor#blockKeydown"
  editor.append(settings, script)
  dom.append(header, editor, output)

  let parts = componentParts(node.attrs.source)
  function syncSettings() {
    const types = new Set(["", ...(catalog.types || []), parts.type])
    for (const name of types) {
      if (![...type.options].some(option => option.value === name)) type.add(new Option(name || "Plain JavaScript", name))
    }
    type.value = parts.type
    const choices = new Set([...(catalog.libraries || []), ...parts.libraries])
    moduleButton.hidden = choices.size === 0
    moduleButton.textContent = parts.libraries.length ? `Modules (${parts.libraries.length})` : "Modules"
    const typeModules = catalog.typeModules?.[parts.type]
    for (const name of choices) {
      let input = [...libraries.querySelectorAll("input")].find(input => input.value === name)
      if (!input) {
        input = document.createElement("input")
        input.type = "checkbox"
        input.value = name
        input.dataset.action = "change->coplan--editor#componentFieldChanged"
        const label = document.createElement("label")
        const note = document.createElement("small")
        note.textContent = "Included with type"
        label.append(input, document.createTextNode(name), note)
        libraries.append(label)
      }
      input.disabled = Array.isArray(typeModules) && typeModules.includes(name) && !parts.libraries.includes(name)
      input.checked = input.disabled || parts.libraries.includes(name)
      input.parentElement.querySelector("small").hidden = !input.disabled
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
    editor.hidden = !editing
    output.hidden = editing
    for (const button of buttons) button.setAttribute("aria-pressed", String(button.dataset.componentView === mode))
    if (editing) {
      generation++
      script.focus({ preventScroll: true })
    } else render()
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
        if (previousHeader !== parts.header) syncSettings()
        if (!output.hidden) render()
      }
      return true
    },
    stopEvent: () => true, ignoreMutation: () => true, destroy() { generation++ }
  }
}
