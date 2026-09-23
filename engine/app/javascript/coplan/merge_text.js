import { diffChars } from "diff"

export class MergeConflict extends Error {}
export function textHunks(before, after) {
  const result = []
  let position = 0, pending = null
  for (const part of diffChars(before, after)) {
    if (!part.added && !part.removed) {
      if (pending) result.push(pending)
      pending = null
      position += part.value.length
    } else {
      pending ||= { from: position, to: position, text: "" }
      if (part.removed) { position += part.value.length; pending.to = position }
      else pending.text += part.value
    }
  }
  if (pending) result.push(pending)
  return result
}
function overlaps(a, b) {
  if (a.from === a.to && b.from === b.to) return a.from === b.from
  if (a.from === a.to) return a.from > b.from && a.from < b.to
  if (b.from === b.to) return b.from > a.from && b.from < a.to
  return a.from < b.to && b.from < a.to
}
export function mergeText(base, local, remote) {
  if (local === base || local === remote) return remote
  if (remote === base) return local
  const ours = textHunks(base, local), theirs = textHunks(base, remote)
  const same = (a, b) => a.from === b.from && a.to === b.to && a.text === b.text
  for (const a of ours) for (const b of theirs) {
    if (!same(a, b) && overlaps(a, b)) throw new MergeConflict("Both edits change the same passage")
  }
  const edits = [...theirs, ...ours.filter(a => !theirs.some(b => same(a, b)))].sort((a, b) => b.from - a.from || b.to - a.to)
  return edits.reduce((text, edit) => text.slice(0, edit.from) + edit.text + text.slice(edit.to), base)
}
export function mergeField(base, local, remote, label) {
  if (local === base || local === remote) return remote
  if (remote === base) return local
  throw new MergeConflict(`Both edits change the ${label}`)
}
