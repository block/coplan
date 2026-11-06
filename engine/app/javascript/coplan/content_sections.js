// The rendered document may alternate prose and slide roots. Walk their
// blocks in document order so section keys remain global across regions.
// A summary card is a wrapper too: its blocks belong to the sections around it.
export function renderedBlocks(root) {
  const regions = root.matches?.(".markdown-rendered") ? [root] :
    Array.from(root.querySelectorAll(".markdown-rendered"))
  return regions.flatMap(region => logicalChildren(region))
}

function logicalChildren(parent) {
  return Array.from(parent.children).flatMap(child =>
    child.matches(".deck-body, .deck-media, .plan-summary") ? logicalChildren(child) : [child])
}
