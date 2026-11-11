import { Fragment, Slice } from "prosemirror-model"
import { Plugin, PluginKey } from "prosemirror-state"
import { Decoration, DecorationSet } from "prosemirror-view"
import { closeHistory } from "prosemirror-history"

// Upload markers live outside the document and map through every local/remote
// transaction. Neither a pending upload nor its failure can enter saved Markdown.
export function richUploads(schema, uploadFiles, reportError, documentTitle) {
  const key = new PluginKey("coplan-uploads"), pending = new Set()
  let destroyed = false
  const hasFiles = event => Array.from(event.dataTransfer?.types || []).includes("Files")
  const clearDrag = view => view.dom.classList.remove("is-file-drop-target")
  function start(view, files, position) {
    const id = crypto.randomUUID(), $pos = view.state.doc.resolve(position)
    if (documentTitle && position < view.state.doc.firstChild.nodeSize) position = view.state.doc.firstChild.nodeSize
    else if ($pos.parent.type.spec.code || $pos.parent.type.name === "template_note") position = $pos.after()
    const marker = document.createElement("span")
    marker.className = "document-editor__upload-placeholder"
    marker.setAttribute("role", "status")
    marker.textContent = `Uploading ${files.map(file => file.name).join(", ")}…`
    view.dispatch(view.state.tr.setMeta(key, { add: Decoration.widget(position, marker, { id, side: -1 }) }))
    const task = (async () => {
      try {
        const attachments = await uploadFiles(files)
        if (destroyed) return
        const placeholder = key.getState(view.state).find().find(item => item.spec.id === id)
        if (!placeholder) {
          if (attachments.length) reportError("Files uploaded to Attachments. Their insertion point was removed; copy their Markdown there to embed them.")
          return
        }
        const blocks = attachments.map(file => schema.nodes.paragraph.create(null,
          file.content_type.startsWith("image/") ? schema.nodes.image.create({ src: file.url, alt: file.filename }) :
            schema.text(file.filename, [schema.marks.link.create({ href: file.download_url })])))
        const tr = view.state.tr.setMeta(key, { remove: id })
        if (blocks.length) {
          tr.replaceRange(placeholder.from, placeholder.from, new Slice(Fragment.fromArray(blocks), 0, 0))
          closeHistory(tr).setMeta("coplan-input-origin", "unknown")
        }
        // Keep the author's current caret and viewport; the drop location may
        // now be offscreen because they continued writing during the upload.
        view.dispatch(tr)
        if (blocks.length) view.dispatch(closeHistory(view.state.tr))
      } catch (error) {
        if (!destroyed) reportError(error.message || "Upload failed. Drop the files again to retry.")
      } finally {
        if (!destroyed) view.dispatch(view.state.tr.setMeta(key, { remove: id }))
      }
    })()
    pending.add(task)
    task.finally(() => pending.delete(task))
  }
  return {
    get uploading() { return pending.size > 0 },
    async whenIdle() { while (pending.size) await Promise.all(pending) },
    plugin: new Plugin({
      key,
      state: {
        init: () => DecorationSet.empty,
        apply(tr, markers) {
          markers = markers.map(tr.mapping, tr.doc)
          const action = tr.getMeta(key)
          if (action?.add) markers = markers.add(tr.doc, [action.add])
          if (action?.remove) markers = markers.remove(markers.find().filter(item => item.spec.id === action.remove))
          return markers
        }
      },
      props: {
        decorations: state => key.getState(state),
        handleDOMEvents: {
          dragover(view, event) {
            if (!hasFiles(event) || view.dragging) return false
            event.preventDefault()
            event.dataTransfer.dropEffect = "copy"
            view.dom.classList.add("is-file-drop-target")
            return true
          },
          dragleave(view, event) {
            if (!view.dom.contains(event.relatedTarget)) clearDrag(view)
            return false
          },
          drop(view) { clearDrag(view); return false }
        },
        handleDrop(view, event, slice, moved) {
          const files = Array.from(event.dataTransfer?.files || [])
          if (!files.length || moved || view.dragging) return false
          const position = view.posAtCoords({ left: event.clientX, top: event.clientY })?.pos
          if (position == null) return false
          start(view, files, position)
          return true
        },
        handlePaste(view, event) {
          const files = Array.from(event.clipboardData?.files || [])
          if (!files.length) return false
          start(view, files, view.state.selection.from)
          return true
        }
      },
      view: () => ({ destroy() { destroyed = true } })
    })
  }
}
