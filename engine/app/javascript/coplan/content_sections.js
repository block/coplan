// A body that opens with an H1 is almost always restating the plan title,
// which heads the document card. The reading view hides that heading (see
// plan-header.css; the server keeps it when an open discussion is anchored
// in it), so it is no section of its own: not in the outline, and no home
// for an update dot.
export const LEADING_HEADING = ".plan-document--titled:not(.plan-document--opening-discussed) #plan-content-body > .markdown-rendered:first-child > h1:first-child"

// The rendered document may alternate prose and slide roots. Walk their
// blocks in document order so section keys remain global across regions.
export function renderedBlocks(root) {
  const regions = root.matches?.(".markdown-rendered") ? [root] :
    Array.from(root.querySelectorAll(".markdown-rendered"))
  return regions.flatMap(region => logicalChildren(region))
}

function logicalChildren(parent) {
  return Array.from(parent.children).flatMap(child =>
    child.matches(".deck-body, .deck-media") ? logicalChildren(child) : [child])
}
