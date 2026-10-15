# CI reliability audit

Audited on October 14, 2026. Scope: all 248 pull requests returned by GitHub
(237 merged, 6 closed, 5 open) and all 843 available CI run records, from
February 20 through October 14. There were 139 failed runs. GitHub retained
logs for 116 of them. Twenty-two older logs returned HTTP 410 (expired),
and one log was missing. The causes of those 23 runs cannot be verified
from the retained logs.

A red build is not automatically a flaky test. Historical logs include
real regressions, lint errors, and stale gem lockfiles. A green rebuild alone
does not prove that a race is fixed.

## Recent recurring failures

| Failure | Evidence | Cause and correction |
| --- | --- | --- |
| Formatting the document | [main](https://github.com/block/coplan/actions/runs/38434727874), [accessibility PR](https://github.com/block/coplan/actions/runs/37959284861) | Removing the last heading collapses the outline and moves the toolbar 244 pixels while Selenium clicks Bold, sometimes hitting Block quote. Keep the outline column fixed during editing. More actions → Show outline gives pointer and touch users an explicit way to reveal a new outline; mobile uses a popover so the paper stays in place. Check its geometry after the outline updates. Also wait for completed editor mounting before typing. |
| Code loses its highlighting after Undo | [demo library PR](https://github.com/block/coplan/actions/runs/38602496501), [accessibility PR](https://github.com/block/coplan/actions/runs/37853049975) | Language changes and code edits can join one history group within 500 ms. Fence the first content edit after language edits. A fixed-clock regression checks Undo and Redo without depending on browser speed. |
| Rapid caret movement escapes code | Found during the local stress runs, including seed 3118 | ArrowDown used the model's old end-of-code caret before native selectionchange caught up. Read the visible caret before deciding to leave code. A same-turn key-event regression forces the lag deterministically. |
| Fit-to-screen changes after zooming | [reliability PR](https://github.com/block/coplan/actions/runs/38632117302) | The initial fit ran before the toolbar and gesture hint reduced the canvas height. Fit again synchronously after mounting those controls. The regression compares the initial scale and readout with the final canvas geometry before any resize callback can run. |
| Removing an iframe misses the button | [validation PR](https://github.com/block/coplan/actions/runs/38651437381), stress seed 9519 | An earlier iframe preview arrives between pointer press and release, moving the Remove button. Preserve a visible pressed or focused control’s screen position when iframe previews finish. Offscreen focus must not pull the page after someone scrolls away to read. Regressions hold the actual preview response until pointer-down at the viewport edge or until the field is offscreen, with browser anchoring disabled. They check removal, Undo, and reading position. |
| Opening a citation misses its button | [review PR](https://github.com/block/coplan/actions/runs/38669925394), seed 16378 | An iframe preview can resize the document during a click on a back-matter citation. Those buttons sit outside ProseMirror, so the earlier control-position guard missed them. Preserve visible pressed/focused controls across the plan's whole editor area. A held-response regression releases the preview on citation pointer-down and requires its dialog to open. The offscreen-focus guard remains in place. |
| An initial quote is absent while the editor boots | [review PR](https://github.com/block/coplan/actions/runs/38671181083), seed 27886 | The anchor regression used the default two-second matcher before inline editing finished mounting. Wait for the visible editable surface using the same readiness condition as the other editor specs. Hold the initial state response for three seconds to prove the check waits for mounting. The post-refresh anchor assertion still requires immediate correctness. |
| Earlier formatting tools never appear after one click | [accessibility PR](https://github.com/block/coplan/actions/runs/38647269966), seed 35406 | The test assumed one partial-page scroll reaches the toolbar's end. Font metrics and host controls can require several pages. Use a deliberately narrow strip, wait for actual scroll completion after each click, and reach the end within a bound derived from the strip's dimensions. Retain the title geometry, hidden scrollbar and accessible end-state assertions. |
| Reviewer menu actions occasionally dismiss without updating | [review PR](https://github.com/block/coplan/actions/runs/38680050764), seed 49208 | A native popover was visible at its default position before queued toggle handling moved it. The review feature now positions its menu during `beforetoggle`. Its progress regressions suppress queued open-toggle handling and assert the initial menu geometry before clicking. This correction lives in #254, where the reviewer menu is introduced. |
| Dictate disappears after a recording test | [review PR](https://github.com/block/coplan/actions/runs/38639424746), seed 54506 | Chrome retained scripts installed by voice tests across later examples. A recording stub disabled speech recognition in comment composers. Remove every installed script after its example. CI also runs a tagged recording-then-dictation pair in that exact order, without a random seed overriding it. |
| Catalog fixtures collide with installed reference data | Fresh seeded PostgreSQL validation, seed 6572; a focused model/API run reproduced four failures in 16 examples | CI installs built-in plan types and harnesses. Fixed-name fixtures and exact catalog-list assertions depended on another spec clearing those rows first. Catalog-configuring groups now establish their own transactional starting state before creating plan fixtures. Production seeds, uniqueness validations, and factory create behavior stay unchanged. |
| A long quote loses its highlight while editing | Local full-suite validation with the external agent-comment branch, PostgreSQL seed 6572 | A saved-thread refresh can arrive after a newer edit and replace mapped highlight ranges with text from the previous acknowledged version. Keep provisional mapped ranges while document content is unsaved, applying thread status changes and removals immediately. Title- or tag-only edits use authoritative refreshed anchors. The regression injects the saved-thread snapshot after the next edit; CI repeats it in five fresh processes per database. |
| Retry closes an editor after background recovery | Seeded demo combination, PostgreSQL seed 6632; forced snapshot-before-click regression reproduces it | Accepting a background snapshot clears the internal retry flag before the scheduled save changes the visible Retry sync control. Dispatch the click from the displayed error state and allow reconnection while that state is shown. A deterministic browser case requires the editor to remain interactive after saving. |
| Dense table lookup exceeds WebDriver's script timeout | Seeded demo combination, MySQL seed 6631 | Searching all 2,880 cells by rendered text asks WebDriver to compute every cell's text. Select the known row/column first and retain the exact text, focus, selection and visibility assertions. CI repeats this case in five fresh processes on each database. |
| Saved or expired-session status is reported as absent | Seeded accessibility combination, MySQL seed 6641; the failure reports that the exact saved message exists twice in non-visible text | The native-style save control intentionally hides its text, and its live announcement is clipped. Browser specs now inspect the editor's actual status text with visibility explicitly set to all, preserving the expected revision, rather than searching only visible page text. Content and revision assertions still verify the saved record. Save checks allow the same 15-second request budget as the editor instead of Capybara’s two-second default. The title-limit case waits for its metadata save before asking Done to close. |
| Reviewer picker geometry changes | [review PR](https://github.com/block/coplan/actions/runs/38643084493), seed 44237 | The browser exposed the open popover before its queued toggle handler positioned it. Wait for the expanded trigger and focused search field before recording geometry. Retain exact panel and manager rectangle comparisons after search. |
| Admin filter inspects an outgoing document | [review PR](https://github.com/block/coplan/actions/runs/38455835339), [accessibility PR](https://github.com/block/coplan/actions/runs/37968935251) | The filtered page still contains the matching row before navigation completes. Wait for each destination URL before querying its DOM. |
| Concurrent plans share a URL | [demo library PR](https://github.com/block/coplan/actions/runs/38455672055), [main](https://github.com/block/coplan/actions/runs/37646742848) | The test shared a mutable user and its lazy library cache across connections. Commit the namespace fixture first and load an independent user per request. Start both connections together and bound thread cleanup. Retain assertions for unique addresses and resolution to each plan. |
| Reading position changes during a remote update | [agent comments PR](https://github.com/block/coplan/actions/runs/37672510420) | Wait for the initial comment anchor to render before recording the reading position. Retain the 24-pixel maximum displacement assertion after the update. |
| Presentation citation preview times out | [editor PR](https://github.com/block/coplan/actions/runs/38460642774) | Already corrected in #251: the scripted sequence has an explicit timeout covering its eight debounced updates. |
| Hover tests fail on headless Linux | Historical image-expansion failures across unrelated branches | Already corrected in #242: supply a desktop pointer and wait for the actual opacity transition. Touch behavior remains separately tested. |

Older failures of removed editing flows and shipped regressions are historical
evidence, not reasons to alter the current assertions. Validate current behavior
with full suites as well as the focused repeated runs below.

## Reproduce and preserve evidence

Use a separate test database when another checkout is running specs. Initialize
MySQL with `RAILS_ENV=test bin/rails db:create db:schema:load`. For PostgreSQL,
set `SCHEMA=tmp/pg_schema.rb` and initialize with `db:create db:migrate`; keep
that `SCHEMA` value set for subsequent spec commands.

```sh
RAILS_ENV=test bin/rspec-stress --runs 20 --seed 3100 \
  spec/system/admin_spec.rb spec/system/editor_code_scope_spec.rb \
  spec/system/human_editing_spec.rb spec/system/image_expand_spec.rb \
  spec/services/coplan/plans/segment_claims_spec.rb
```

Each run starts a fresh Ruby process and uses the next random-order seed.
The command stops at the first failure. It does not retry a failed example.
Logs, RSpec JSON reports, and `summary.json` are saved under
`tmp/rspec-stress/`. An empty suite or boot error also fails the command.

Every PR runs the full suite with a recorded seed on MySQL and PostgreSQL,
then repeats the regression files five times. A separate five-process check forces
the saved-thread anchor refresh race. Another five-process check targets the
dense-table cell lookup. A separate five-process boundary cohort covers slow editor mounting, paged toolbar access, and iframe-preview control positions. CI uploads JSON reports, stress
logs, and browser failure screenshots for 30 days, including on failure.

The voice environment check deliberately runs recording before dictation:

```sh
bundle exec rspec spec/system/voice_commenting_spec.rb \
  spec/system/comment_composer_spec.rb --tag voice_environment --order defined
```

Both examples also remain in the full suite. This order failed before script
cleanup; dictation must still work after the recording example finishes.

## Validation record

Record the commit, database, seed range, example counts, and any failures when
running this audit again. Repeated passes reduce uncertainty; they do not prove
that a test can never fail. Keep genuine regressions visible and fix their cause.
