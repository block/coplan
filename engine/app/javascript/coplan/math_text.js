// KaTeX writes each formula twice (MathML for assistive technology and HTML
// glyphs) plus a TeX annotation, so the textContent of typeset math repeats
// it about three times. Text derived from rendered Markdown — outline labels,
// section ids, section previews — reads formulas as their TeX source
// instead, which is also what they are before KaTeX arrives.
export function readableText(node) {
  if (!node.querySelector?.("[data-math-style]")) return node.textContent

  const copy = node.cloneNode(true)
  copy.querySelectorAll("[data-math-style]").forEach(math => {
    math.replaceWith(math.dataset.mathSource ?? math.textContent)
  })
  return copy.textContent
}
