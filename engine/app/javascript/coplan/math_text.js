const MATH = "[data-math-style]"

// KaTeX writes each formula twice (MathML for assistive technology and HTML
// glyphs) plus a TeX annotation, so the textContent of typeset math repeats
// it about three times. Text derived from rendered Markdown — outline labels,
// section ids, section previews — reads formulas as their TeX source
// instead, which is also what they are before KaTeX arrives. The node may
// itself be a formula: a section's top-level math fence is one block.
export function readableText(node) {
  if (node.matches?.(MATH)) return mathSource(node)
  if (!node.querySelector?.(MATH)) return node.textContent

  const copy = node.cloneNode(true)
  copy.querySelectorAll(MATH).forEach(math => math.replaceWith(mathSource(math)))
  return copy.textContent
}

function mathSource(math) {
  return math.dataset.mathSource ?? math.textContent
}
