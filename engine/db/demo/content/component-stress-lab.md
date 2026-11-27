# Component stress lab

## Service dependency map

Increase the replica count to redraw a denser SVG. Pick a service to isolate its incoming and outgoing links. The counts describe the graph actually drawn.

::: {.component #service-map}

const stages = ["Gateway", "Checkout", "Policy", "Payment", "Ledger", "Events", "Delivery", "Audit"]
root.innerHTML = `<style>
  label,output {font: 14px system-ui} output {display:block; margin:.5em 0}
  svg {width:100%;display:block;background:var(--coplan-surface-muted);border-radius:6px}
  text {fill:var(--coplan-text);font:14px system-ui}
  circle {cursor:pointer;fill:var(--coplan-surface);stroke:var(--coplan-primary);stroke-width:2}
  circle[aria-pressed=true] {fill:var(--coplan-primary)}
</style><label>Replicas per stage <select><option>8</option><option selected>24</option><option>48</option></select></label>
<output aria-live="polite"></output><svg aria-label="Service dependency map"></svg>`
const svg = root.querySelector("svg"), summary = root.querySelector("output")
const control = root.querySelector("select")
function element(name, attrs) {
  const el = document.createElementNS(svg.namespaceURI, name)
  for (const [key, value] of Object.entries(attrs)) el.setAttribute(key, value)
  return el
}
function draw() {
  const replicas = Number(control.value), routes = [], nodes = []
  const height = 48 + replicas * 12
  svg.setAttribute("viewBox", `0 0 840 ${height}`)
  const fragment = document.createDocumentFragment()
  for (let stage = 0; stage < stages.length - 1; stage++) {
    for (let row = 0; row < replicas; row++) {
      for (const offset of [0, 1, 5, 7]) {
        const next = (row + offset) % replicas
        const x = 50 + stage * 105, y = 38 + row * 12, targetY = 38 + next * 12
        const path = element("path", {d: `M${x} ${y} C${x+52} ${y} ${x+52} ${targetY} ${x+105} ${targetY}`,
          fill:"none", stroke:"var(--coplan-text-muted)", opacity:".22"})
        fragment.append(path)
        routes.push({path, from:stage * replicas + row, to:(stage + 1) * replicas + next})
      }
    }
  }
  const counts = `${stages.length * replicas} services · ${routes.length} routes`
  summary.textContent = counts
  function inspect(id) {
    for (const edge of routes) {
      const active = edge.from === id || edge.to === id
      edge.path.setAttribute("stroke", active ? "var(--coplan-primary)" : "var(--coplan-text-muted)")
      edge.path.setAttribute("opacity", active ? "1" : ".08")
    }
    nodes.forEach((node,i) => node.setAttribute("aria-pressed", String(i === id)))
    summary.textContent = counts + " · " + nodes[id].getAttribute("aria-label")
  }
  stages.forEach((stage, col) => {
    const heading = element("text", {x:50+col*105, y:20, "text-anchor":"middle"})
    heading.textContent = stage
    fragment.append(heading)
    for (let row = 0; row < replicas; row++) {
      const id = nodes.length
      const node = element("circle",{cx:50+col*105, cy:38+row*12, r:4, role:"button", tabindex:0,
        "aria-label":stage + " replica " + (row+1), "aria-pressed":false})
      node.onclick = () => inspect(id)
      node.onkeydown = e => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); inspect(id) } }
      nodes.push(node)
      fragment.append(node)
    }
  })
  svg.replaceChildren(fragment)
}
control.onchange = draw
draw()

:::

## Queue saturation

Run a deterministic burst through 256 queues. Each run computes backlog at every time step and aggregates the results into a heat map. Increase the time window to compare the workload. Darker cells indicate larger backlogs.

::: {.component #queue-saturation}

root.innerHTML = `<style>
  label,button,output {font:14px system-ui} button {margin-left:8px}
  canvas {display:block;width:100%;height:200px;margin:10px 0;background:#f1f5ff;image-rendering:pixelated}
</style><label>Time steps <select><option>2048</option><option selected>8192</option><option>32768</option></select></label>
<button type="button">Run simulation</button><canvas width="256" height="256" aria-label="Queue backlog over time"></canvas><output aria-live="polite"></output>`
const canvas = root.querySelector("canvas"), ctx = canvas.getContext("2d")
const run = root.querySelector("button"), steps = root.querySelector("select"), output = root.querySelector("output")
async function simulate() {
  run.disabled = steps.disabled = true
  const ticks = Number(steps.value), pixels = ctx.createImageData(256,256), bucket = ticks/256
  const started = performance.now()
  let peak = 0, random = 12345
  for (let queue = 0; queue < 256; queue++) {
    if (queue % 16 === 0) {
      output.textContent = `Simulating queues ${queue+1}–${queue+16} of 256…`
      await new Promise(resolve => requestAnimationFrame(resolve))
    }
    let backlog = 0, sum = 0
    for (let tick = 0; tick < ticks; tick++) {
      random = (Math.imul(1664525,random) + 1013904223) >>> 0
      const burst = (Math.floor(tick / bucket) + (queue >> 2)) % 70 < 16
      const arrivals = (random >>> 28) % (burst ? 9 : 5)
      backlog = Math.max(0, backlog + arrivals - 3)
      peak = Math.max(peak, backlog)
      sum += backlog
      if ((tick + 1) % bucket === 0) {
        const intensity = Math.min(1, sum / (bucket * bucket * 10))
        const i = 4*(queue*256 + Math.floor(tick/bucket))
        pixels.data.set([239-210*intensity,245-162*intensity,255-110*intensity,255],i)
        sum = 0
      }
    }
  }
  ctx.putImageData(pixels,0,0)
  output.textContent = `${(ticks*256).toLocaleString("en-US")} queue updates · peak backlog ${peak} · ${Math.round(performance.now()-started)} ms elapsed`
  run.disabled = steps.disabled = false
}
run.onclick = simulate
await simulate()

:::
