# CI reliability audit

Audited on October 14, 2026. Scope: all 248 pull requests returned by GitHub
(237 merged, 6 closed, 5 open) and all 843 available CI run records, from
February 20 through October 14. There were 139 failed runs. One failed-run
log was unavailable, so its cause cannot be verified from GitHub.

A red build is not automatically a flaky test. Historical logs include
real regressions, lint errors, and stale gem lockfiles. A green rebuild alone
does not prove that a race is fixed.

## Recent recurring failures

| Failure | Evidence | Cause and correction |
| --- | --- | --- |
| Formatting the document | [main](https://github.com/block/coplan/actions/runs/38434727874), [accessibility PR](https://github.com/block/coplan/actions/runs/37959284861) | Removing the last heading collapses the outline and moves the toolbar 244 pixels while Selenium clicks Bold, sometimes hitting Block quote. Keep the outline column fixed during editing. Check its geometry after the outline updates. Also wait for completed editor mounting before typing. |
| Code loses its highlighting after Undo | [demo library PR](https://github.com/block/coplan/actions/runs/38602496501), [accessibility PR](https://github.com/block/coplan/actions/runs/37853049975) | Language changes and code edits can join one history group within 500 ms. Fence the first content edit after language edits. A fixed-clock regression checks Undo and Redo without depending on browser speed. |
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
  spec/system/human_editing_spec.rb spec/services/coplan/plans/segment_claims_spec.rb
```

Each run starts a fresh Ruby process and uses the next random-order seed.
The command stops at the first failure. It does not retry a failed example.
Logs, RSpec JSON reports, and `summary.json` are saved under
`tmp/rspec-stress/`. An empty suite or boot error also fails the command.

Every PR runs the full suite with a recorded seed on MySQL and PostgreSQL,
then repeats the regression files five times. CI uploads JSON reports, stress
logs, and browser failure screenshots for 30 days, including on failure.

## Validation record

Record the commit, database, seed range, example counts, and any failures when
running this audit again. Repeated passes reduce uncertainty; they do not prove
that a test can never fail. Keep genuine regressions visible and fix their cause.
