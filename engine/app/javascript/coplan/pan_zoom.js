// Pan and zoom over a fixed-size piece of content inside a viewport.
// Written for Mermaid SVGs but deliberately knows nothing about them: it
// takes a viewport, a content element, and the content's natural size, and
// drives a transform.
//
// Gestures: drag to pan, wheel to zoom at the cursor, two-finger pinch to
// zoom, shift+wheel to pan sideways, double-click to toggle fit and close-
// up, and +/-/0/1/arrows from the keyboard.

const KEYS = new Set([ "+", "=", "-", "_", "0", "1", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight" ])

export function createPanZoom(viewport, content, {
  width,
  height,
  min = 0.1,
  max = 8,
  padding = 24,
  // Fitting a three-node diagram to a 1400px screen would blow it up to a
  // cartoon. Fit is allowed to enlarge, but only so far.
  maxFit = 2,
  onChange = null
} = {}) {
  const abort = new AbortController()
  const signal = abort.signal
  const pointers = new Map()

  let scale = 1
  let x = 0
  let y = 0
  let fitScale = 1
  let fitted = true
  let gestureStart
  let dragged = false

  content.style.position = "absolute"
  content.style.top = "0"
  content.style.left = "0"
  content.style.transformOrigin = "0 0"
  content.style.width = `${width}px`
  content.style.height = `${height}px`
  content.style.maxWidth = "none"

  function apply() {
    const box = viewport.getBoundingClientRect()
    x = clampAxis(x, width * scale, box.width)
    y = clampAxis(y, height * scale, box.height)
    content.style.transform = `translate3d(${x}px, ${y}px, 0) scale(${scale})`
    onChange?.(scale)
  }

  function setScale(next, anchorX, anchorY) {
    const clamped = Math.min(max, Math.max(Math.min(min, fitScale), next))
    if (clamped === scale) return
    fitted = false
    const ratio = clamped / scale
    // Hold the content point under the anchor still.
    x = anchorX - ratio * (anchorX - x)
    y = anchorY - ratio * (anchorY - y)
    scale = clamped
    apply()
  }

  function viewportPoint(event) {
    const box = viewport.getBoundingClientRect()
    return [ event.clientX - box.left, event.clientY - box.top ]
  }

  function center() {
    const box = viewport.getBoundingClientRect()
    return [ box.width / 2, box.height / 2 ]
  }

  function fit() {
    const box = viewport.getBoundingClientRect()
    const available = { width: Math.max(1, box.width - padding * 2), height: Math.max(1, box.height - padding * 2) }
    fitScale = Math.min(maxFit, available.width / width, available.height / height)
    fitted = true
    scale = fitScale
    // Fit always contains the full diagram, even below the normal zoom minimum.
    x = width * scale <= box.width ? (box.width - width * scale) / 2 : 0
    y = height * scale <= box.height ? (box.height - height * scale) / 2 : 0
    apply()
  }

  function actualSize() {
    const [ cx, cy ] = center()
    setScale(1, cx, cy)
  }

  function zoomBy(factor, anchor) {
    const [ ax, ay ] = anchor || center()
    setScale(scale * factor, ax, ay)
  }

  viewport.addEventListener("wheel", event => {
    event.preventDefault()
    if (event.shiftKey && !event.ctrlKey) {
      fitted = false
      x -= event.deltaY || event.deltaX
      apply()
      return
    }
    // A trackpad pinch arrives as ctrl+wheel with much smaller deltas than
    // a mouse wheel notch, so it needs a stronger multiplier to feel 1:1.
    const intensity = event.ctrlKey ? 0.012 : 0.0022
    const step = event.deltaMode === 1 ? event.deltaY * 16 : event.deltaY
    setScale(scale * Math.exp(-step * intensity), ...viewportPoint(event))
  }, { passive: false, signal })

  viewport.addEventListener("pointerdown", event => {
    if (event.button !== 0 && event.pointerType === "mouse") return
    if (pointers.size === 0) dragged = false
    if (event.target.closest("a, button")) return
    if (pointers.size === 0) {
      gestureStart = { x: event.clientX, y: event.clientY }
      dragged = false
    } else dragged = true
    pointers.set(event.pointerId, { x: event.clientX, y: event.clientY })
    viewport.classList.add("is-grabbing")
  }, { signal })

  viewport.addEventListener("pointermove", event => {
    const previous = pointers.get(event.pointerId)
    if (!previous) return
    const current = { x: event.clientX, y: event.clientY }
    if (distance(gestureStart, current) > 6) dragged = true
    if (!dragged) return
    viewport.setPointerCapture(event.pointerId)

    if (pointers.size === 1) {
      fitted = false
      x += current.x - previous.x
      y += current.y - previous.y
      pointers.set(event.pointerId, current)
      apply()
      return
    }

    if (pointers.size === 2) {
      const other = [ ...pointers.entries() ].find(([ id ]) => id !== event.pointerId)?.[1]
      if (!other) return
      const box = viewport.getBoundingClientRect()
      const before = distance(previous, other)
      const after = distance(current, other)
      const midBefore = midpoint(previous, other, box)
      const midAfter = midpoint(current, other, box)
      pointers.set(event.pointerId, current)

      // Pan by how far the grip moved, then scale about where it now is.
      x += midAfter[0] - midBefore[0]
      y += midAfter[1] - midBefore[1]
      if (before > 0) setScale(scale * (after / before), ...midAfter)
      else apply()
    }
  }, { signal })

  const release = event => {
    pointers.delete(event.pointerId)
    if (pointers.size === 0) viewport.classList.remove("is-grabbing")
  }
  viewport.addEventListener("pointerup", release, { signal })
  viewport.addEventListener("pointercancel", release, { signal })
  viewport.addEventListener("click", event => {
    if (!dragged) return
    dragged = false
    event.preventDefault()
    event.stopImmediatePropagation()
  }, { signal, capture: true })

  viewport.addEventListener("dblclick", event => {
    event.preventDefault()
    // Near the fit scale, a double-click means "let me look closer"; from
    // anywhere else it means "show me the whole thing again".
    if (Math.abs(scale - fitScale) < 0.01) setScale(Math.max(1, fitScale * 2), ...viewportPoint(event))
    else fit()
  }, { signal })

  viewport.addEventListener("keydown", event => {
    if (event.metaKey || event.ctrlKey || !KEYS.has(event.key)) return
    event.preventDefault()
    const step = event.shiftKey ? 200 : 60
    if (event.key.startsWith("Arrow")) fitted = false
    switch (event.key) {
      case "+": case "=": zoomBy(1.25); break
      case "-": case "_": zoomBy(0.8); break
      case "0": fit(); break
      case "1": actualSize(); break
      case "ArrowUp": y += step; apply(); break
      case "ArrowDown": y -= step; apply(); break
      case "ArrowLeft": x += step; apply(); break
      case "ArrowRight": x -= step; apply(); break
    }
  }, { signal })

  const resize = new ResizeObserver(() => fitted ? fit() : apply())
  resize.observe(viewport)

  fit()

  return {
    fit,
    actualSize,
    zoomIn: () => zoomBy(1.25),
    zoomOut: () => zoomBy(0.8),
    get scale() { return scale },
    destroy: () => {
      abort.abort()
      resize.disconnect()
    }
  }
}

// Keeps the content anchored to the viewport: when it's larger, no empty
// gap can be dragged in; when it's smaller, it stays fully visible.
function clampAxis(position, scaledLength, viewportLength) {
  if (scaledLength <= viewportLength) {
    return Math.min(Math.max(position, 0), viewportLength - scaledLength)
  }
  return Math.min(Math.max(position, viewportLength - scaledLength), 0)
}

function distance(a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y)
}

function midpoint(a, b, box) {
  return [ (a.x + b.x) / 2 - box.left, (a.y + b.y) / 2 - box.top ]
}
