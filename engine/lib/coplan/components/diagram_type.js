import { Diagram } from "diagram"

export function setup({ title }) {
  return { diagram: new Diagram(title) }
}

export function mount({ diagram, root }) {
  diagram.render(root)
}
