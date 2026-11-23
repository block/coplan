## Payment path

Checkout submits the first attempt. A failed attempt enters the retry queue. In the document editor, choose Edit on the diagram, change a node label, then choose Preview.

::: {.component type="diagram"}

diagram.node("checkout", "Checkout");
diagram.node("retry", "Retry queue");
diagram.edge("checkout", "retry", "on failure");

:::

## Explore backoff

Choose how many attempts fail before a payment succeeds. Each retry doubles the previous wait. To discuss a particular delay, choose Comment below the simulator and drag across the result.

::: {.component}

const label = document.createElement("label");
const slider = document.createElement("input");
slider.type = "range";
slider.min = 1;
slider.max = 6;
slider.value = 3;
label.append("Failed attempts ", slider);
const result = document.createElement("output");
result.setAttribute("aria-live", "polite");
result.style.cssText = "display:block;margin-top:.8em;font-variant-numeric:tabular-nums";
function draw() {
  const waits = Array.from({length: Number(slider.value)}, (_, i) => 2 ** i);
  result.textContent = waits.join(" + ") + " = " + waits.reduce((a, b) => a + b) + " seconds";
}
slider.addEventListener("input", draw);
root.append(label, result);
draw();

:::
