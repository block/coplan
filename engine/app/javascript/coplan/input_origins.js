import { textHunks } from "coplan/merge_text"

// Keep the already-serialized strings by reference while someone types.
// Diff only on save or when the input source changes, never per keystroke.
export class InputOrigins {
  constructor(content, saved = null) {
    this.content = content
    this.source = typeof saved?.source === "string" ? saved.source : content
    this.runs = Array.isArray(saved?.runs) && saved.runs.length <= 4096 &&
      saved.runs.every(run => Array.isArray(run) && Number.isInteger(run[0]) && run[0] > 0 && ["human", "unknown"].includes(run[1])) &&
      saved.runs.reduce((sum, run) => sum + run[0], 0) === this.source.length ? saved.runs : [[this.source.length, "unknown"]]
    this.kind = saved?.kind === "human" ? "human" : "unknown"
    this.history = new Map()
    this.remember()
  }

  record(content, kind = "unknown") {
    if (content === this.content) return
    if (kind && typeof kind === "object") {
      this.flush()
      const runs = kind.runs
      const valid = kind.source === content && Array.isArray(runs) && runs.length <= 4096 &&
        runs.every(run => Array.isArray(run) && Number.isInteger(run[0]) && run[0] > 0 && ["human", "unknown"].includes(run[1])) &&
        runs.reduce((sum, run) => sum + run[0], 0) === content.length
      this.content = content
      this.kind = "unknown"
      this.flush(valid ? runs : null)
      return
    }
    const history = kind === "history"
    kind = kind === "human" ? "human" : "unknown"
    if (kind !== this.kind || history) this.flush()
    if (history && this.history.has(content)) {
      this.source = content
      this.runs = this.history.get(content).map(run => [...run])
    }
    this.kind = kind
    this.content = content
  }

  static slice(runs, from, to) { return slice(runs, from, to) }

  flush(evidence = null) {
    if (this.source === this.content) return
    const before = this.source, after = this.content
    let prefix = 0, suffix = 0
    while (prefix < before.length && prefix < after.length && before[prefix] === after[prefix]) prefix++
    if (prefix && /[\uD800-\uDBFF]/.test(before[prefix - 1])) prefix--
    while (suffix < before.length - prefix && suffix < after.length - prefix && before[before.length - suffix - 1] === after[after.length - suffix - 1]) suffix++
    if (suffix && /[\uDC00-\uDFFF]/.test(before[before.length - suffix])) suffix--
    const oldMiddle = before.slice(prefix, before.length - suffix), newMiddle = after.slice(prefix, after.length - suffix)
    const edits = oldMiddle.length * newMiddle.length > 1_000_000 ?
      [{from: prefix, to: before.length - suffix, text: newMiddle, kind: "unknown"}] :
      textHunks(oldMiddle, newMiddle).map(edit => ({...edit, from: edit.from + prefix, to: edit.to + prefix, kind: this.kind}))
    let delta = 0
    for (const edit of edits) {
      edit.runs = evidence ? slice(evidence, edit.from + delta, edit.from + delta + edit.text.length) : [[edit.text.length, edit.kind]]
      delta += edit.text.length - (edit.to - edit.from)
    }
    for (const edit of edits.reverse()) {
      this.runs = coalesce([...slice(this.runs, 0, edit.from), ...edit.runs, ...slice(this.runs, edit.to, this.runs.reduce((sum, run) => sum + run[0], 0))])
    }
    if (this.runs.length > 4096) this.runs = [[after.length, "unknown"]]
    this.source = after
    this.remember()
  }

  remember() {
    this.history.set(this.source, this.runs.map(run => [...run]))
    // Retain a bounded set of exact undo checkpoints, not a keystroke log.
    while (this.history.size > 16 || [...this.history.keys()].reduce((sum, text) => sum + text.length, 0) > 2_000_000) this.history.delete(this.history.keys().next().value)
  }

  payload() { this.flush(); return {runs: this.runs} }
  draft() { return {source: this.source, runs: this.runs, kind: this.kind} }
}

function slice(runs, from, to) {
  const result = []
  let offset = 0
  for (const [length, kind] of runs) {
    const count = Math.min(to, offset + length) - Math.max(from, offset)
    if (count > 0) result.push([count, kind])
    offset += length
    if (offset >= to) break
  }
  return result
}
function coalesce(runs) {
  const result = []
  for (const [length, kind] of runs) {
    if (!length) continue
    if (result.at(-1)?.[1] === kind) result.at(-1)[0] += length
    else result.push([length, kind])
  }
  return result
}
