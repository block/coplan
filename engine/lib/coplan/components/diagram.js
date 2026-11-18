// A small SVG graph. Nodes follow declaration order; edges refer to their IDs.
export class Diagram {
  constructor(title = "Diagram") {
    this.title = title
    this.nodes = new Map()
    this.edges = []
  }

  node(id, label) {
    this.nodes.set(id, label)
  }

  edge(from, to, label = "") {
    this.edges.push({ from, to, label })
  }

  render(root) {
    const svgElement = (name, attrs, text) => {
      const el = document.createElementNS("http://www.w3.org/2000/svg", name)
      for (const [key, value] of Object.entries(attrs)) el.setAttribute(key, value)
      if (text !== undefined) el.textContent = text
      return el
    }
    const width = 560
    const svg = svgElement("svg", {viewBox: `0 0 ${width} ${Math.max(90, this.nodes.size * 96)}`, role: "img", "aria-label": this.title})
    svg.style.cssText = "display:block;width:100%;max-width:560px;margin:auto;font:15px system-ui;color:CanvasText"
    const positions = new Map()
    for (const [id, label] of this.nodes) {
      const y = 12 + positions.size * 96
      positions.set(id, y)
      svg.append(svgElement("rect", {x: 128, y, width: 304, height: 44, rx: 8, fill: "Canvas", stroke: "currentColor"}))
      svg.append(svgElement("text", {x: 280, y: y + 27, "text-anchor": "middle", fill: "currentColor"}, label))
    }
    this.edges.forEach(({from, to, label}, index) => {
      if (!positions.has(from) || !positions.has(to)) throw new Error("Each edge needs two declared nodes")
      const start = positions.get(from), end = positions.get(to)
      const lane = 445 + (index % 5) * 13
      const adjacent = end === start + 96
      const path = adjacent ? `M280 ${start + 44} V${end - 4}` :
        `M432 ${start + 16} H${lane} V${end + 30} H436`
      svg.prepend(svgElement("path", {d: path, fill: "none", stroke: "currentColor"}))
      const head = adjacent ? `M276 ${end - 7} l4 7 4 -7` : `M439 ${end + 26} l-7 4 7 4`
      svg.append(svgElement("path", {d: head, fill: "currentColor"}))
      svg.append(svgElement("text", {x: adjacent ? 291 : lane + 3, y: (start + end) / 2 + 23, fill: "currentColor", "font-size": 12}, label))
    })
    root.replaceChildren(svg)
  }
}
