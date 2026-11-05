// The round trip of a rendered diagram in CoPlan. Run: node render.mjs
// Needs Node 22.3+ and the draw-diagram skill (set DRAW_DIAGRAM_SKILL to use
// a checkout). Writes rendered-diagram.png, .svg and .html next to this file.
//
// Notes for the next editor: keep the four numbered steps in this order, and
// keep CoPlan in the middle column so both agents connect to it directly.
import { homedir } from 'node:os';
const skill = process.env.DRAW_DIAGRAM_SKILL ?? `${homedir()}/.agents/skills/draw-diagram`;
const { Diagram, BLUE, TEAL, GRAY, INK } = await import(`${skill}/scripts/diagram.mjs`);

const d = new Diagram('A rendered diagram keeps its source', {
  desc: '1: the drawing agent puts the source in the plan with the PNG rendered from it. '
    + '2: a reviewer asks for a change. 3: another agent reads the source from the plan. '
    + '4: it renders again and puts the edited source and new PNG in the plan.',
});
d.legend(0, 0, [['Agent', BLUE], ['CoPlan', TEAL], ['Person', GRAY]]);

// Three 240-wide columns with 170px gutters for a badge and label. The
// editing agent sits under CoPlan; its two connectors run 80px apart.
const [W, H] = [240, 120];
const C = [0, 1, 2].map((i) => i * (W + 170));
const [R1, R2] = [70, 330];
const m1 = R1 + H / 2;
const cx = C.map((c) => c + W / 2);
const gut = [0, 1].map((i) => (C[i] + W + C[i + 1]) / 2);

d.box(C[0], R1, W, H, 'Drawing agent', ['Renders render.mjs'], 'Agent · laptop', BLUE);
d.system(C[1], R1, W, H, 'CoPlan', ['Source in the plan,', 'image attached'], 'Plan document', TEAL);
d.person(cx[2], m1 - 14, 'Reviewer');
d.box(C[1], R2, W, H, 'Editing agent', ['Edits and renders again'], 'Agent · any machine', BLUE);

d.rel(`M${C[0] + W} ${m1}H${C[1] - 4}`, 'Edits the plan', 'source + image', { at: [gut[0], m1], n: 1, n_color: INK });
d.rel(`M${cx[2] - 34} ${m1 - 14}H${C[1] + W + 4}`, 'Asks for a change', 'comment',
  { at: [gut[1], m1 - 14], n: 2, n_color: INK });
const mid = (R1 + H + R2) / 2;
d.rel(`M${cx[1] - 40} ${R1 + H}V${R2 - 4}`, 'Reads the source', 'from the plan',
  { at: [cx[1] - 40, mid], side: 'left', n: 3, n_color: INK });
d.rel(`M${cx[1] + 40} ${R2}V${R1 + H + 4}`, 'Edits the plan', 'source + new image',
  { at: [cx[1] + 40, mid], side: 'right', n: 4, n_color: INK });

d.save(import.meta.dirname, 'rendered-diagram');
