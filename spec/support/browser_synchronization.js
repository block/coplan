// A received Turbo Stream still has a repaint and possibly an async renderer
// ahead of it. Track that work for HTTP responses and WebSocket broadcasts.
document.addEventListener("turbo:before-stream-render", event => {
  const lockstep = window.CapybaraLockstep
  let pending = true
  const finish = () => {
    if (!pending) return
    pending = false
    lockstep.stopWork("Turbo Stream")
  }

  lockstep.startWork("Turbo Stream")
  // Other listeners may wrap the renderer or cancel the stream. Capture their
  // final renderer after dispatch, before Turbo's next-repaint render step.
  queueMicrotask(() => {
    if (event.defaultPrevented) {
      finish()
      return
    }
    const render = event.detail.render
    event.detail.render = async stream => {
      try {
        return await render(stream)
      } finally {
        finish()
      }
    }
  })
}, { capture: true })
