// A closed <details> keeps its content in the DOM. Highlights inside it
// exist, and Chrome even reports client rects for them, but the reader
// cannot see them. Its <summary> stays visible, so content there is not
// hidden by its own section.

function hiddenBy(details, element) {
  return !details.open && !details.querySelector(":scope > summary")?.contains(element)
}

function* sections(element) {
  for (let details = element.closest("details"); details; details = details.parentElement?.closest("details")) {
    yield details
  }
}

// The outermost closed section hiding the element: the one whose summary
// the reader can currently see.
export function hidingSection(element) {
  let hiding = null
  for (const details of sections(element)) if (hiddenBy(details, element)) hiding = details
  return hiding
}

// Open every section that hides the element. Returns whether any opened.
export function revealSections(element) {
  let revealed = false
  for (const details of sections(element)) {
    if (!hiddenBy(details, element)) continue
    details.open = true
    revealed = true
  }
  return revealed
}
