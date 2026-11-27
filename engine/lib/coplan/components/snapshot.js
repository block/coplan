// Executed only inside the component frame. Copy the visible state synchronously
// before decoding the image, so animation can continue while the reader drags.
async function captureSnapshot(root, point) {
  const width = innerWidth
  const height = innerHeight
  const target = document.elementFromPoint(point.x, point.y)
  const label = (target?.getAttribute("aria-label") || target?.labels?.[0]?.textContent ||
    (target !== root && target !== document.body && target?.textContent) || "").trim().slice(0, 160)
  try {
    const svgNS = "http://www.w3.org/2000/svg"
    const doc = document.implementation.createDocument(svgNS, "svg")
    const svg = doc.documentElement
    const scale = Math.min(devicePixelRatio || 1, 2, 1536 / width, 1536 / height)
    const canvas = document.createElement("canvas")
    canvas.width = Math.max(1, Math.round(width * scale))
    canvas.height = Math.max(1, Math.round(height * scale))
    svg.setAttribute("width", canvas.width)
    svg.setAttribute("height", canvas.height)
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
    const surface = doc.createElementNS(svgNS, "foreignObject")
    surface.setAttribute("width", width)
    surface.setAttribute("height", height)
    svg.append(surface)
    const localReference = location.href.split("#")[0] + "#"
    let count = 0
    function copy(node) {
      if (++count > 6000) throw Error("Component is too large to capture")
      if (node.nodeType === Node.TEXT_NODE) return doc.createTextNode(node.data)
      if (!(node instanceof Element) || node.matches("script, style, link, meta")) return null
      if (node.shadowRoot || node.matches("video, iframe, object")) throw Error("Unsupported surface")
      const style = getComputedStyle(node)
      if (style.display === "none") return null
      if (node !== document.scrollingElement && (node.scrollTop || node.scrollLeft)) throw Error("Scrolled content")
      const clone = node instanceof HTMLCanvasElement ? doc.createElementNS(root.namespaceURI, "img") : doc.importNode(node, false)
      if (node instanceof SVGElement) {
        for (const attr of clone.attributes) {
          if (attr.value.includes(localReference)) attr.value = attr.value.replaceAll(localReference, "#")
        }
      }
      if (node instanceof HTMLCanvasElement) clone.setAttribute("src", node.toDataURL())
      if (node instanceof HTMLInputElement) {
        clone.setAttribute("value", node.value)
        clone.toggleAttribute("checked", node.checked)
      }
      if (node instanceof HTMLOptionElement) clone.toggleAttribute("selected", node.selected)
      // Computed values capture the active theme and the current animation frame.
      const css = style.cssText || Array.from(style, key => key + ":" + style.getPropertyValue(key)).join(";")
      clone.style.cssText = css.replaceAll(localReference, "#")
      clone.style.animation = "none"
      clone.style.transition = "none"
      if (node instanceof HTMLTextAreaElement) clone.textContent = node.value
      else for (const child of node.childNodes) {
        const copied = copy(child)
        if (copied) clone.append(copied)
      }
      return clone
    }
    const body = copy(document.body)
    body.style.transform = `translate(${-scrollX}px,${-scrollY}px)`
    surface.append(body)
    const image = new Image()
    const xml = new XMLSerializer().serializeToString(svg)
    if (xml.length > 12 * 1024 * 1024) return {label}
    image.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(xml)
    await image.decode()
    const context = canvas.getContext("2d")
    context.fillStyle = getComputedStyle(document.documentElement).getPropertyValue("--coplan-surface") || "white"
    context.fillRect(0, 0, canvas.width, canvas.height)
    context.drawImage(image, 0, 0)
    const png = await new Promise(resolve => canvas.toBlob(resolve, "image/png"))
    return {label, png: png?.size <= 4 * 1024 * 1024 ? png : null}
  } catch {
    return {label}
  }
}
