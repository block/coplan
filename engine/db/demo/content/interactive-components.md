## Payment path

Checkout submits the first attempt. A failed attempt enters the retry queue. In the editor, change a label in the SVG below and choose **Preview**. To make your own component, choose **+ → Component → Base**. Its **Quick guide** introduces the JavaScript you can use.

::: {.component title="Payment path"}

root.innerHTML = `
  <svg viewBox="0 0 400 88" width="400" style="display:block;max-width:100%;margin:auto"
       role="img" aria-label="A failed checkout enters the retry queue">
    <g fill="var(--coplan-surface-muted)" stroke="var(--coplan-border)">
      <rect x="4" y="24" width="116" height="44" rx="8"/>
      <rect x="280" y="24" width="116" height="44" rx="8"/>
    </g>
    <path d="M120 46h154m-7-6 7 6-7 6" fill="none" stroke="currentColor"/>
    <g fill="currentColor" text-anchor="middle">
      <text x="62" y="51">Checkout</text>
      <text x="200" y="37" font-size="13">on failure</text>
      <text x="338" y="51">Retry queue</text>
    </g>
  </svg>`;

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
