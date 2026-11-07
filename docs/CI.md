# GitHub CI

## Local checks in parallel

Run `bundle install` and start MySQL, then use:

```sh
bin/ci
```

This runs every RSpec file, including real-browser system specs, plus RuboCop,
the gem and importmap audits, Brakeman, and the demo seeds twice. It does not
run `bin/setup`, alter the development database, or replant your usual test
database. Dependencies must already be installed. Chrome for Testing is
provisioned by Selenium using the same local configuration as ordinary system specs.

The default worker budget is half the detected CPU count, capped at eight and
at least one. Up to four workers run browser shards; the remaining slots can
run other specs or checks at the same time. RuboCop's own parallelism is disabled
so it shares this budget. To use more cores or less memory:

```sh
bin/ci --jobs 12 --browser-jobs 6
bin/ci --jobs 2 --browser-jobs 1
bin/ci --jobs 1
```

Each RSpec shard and the seed check get a newly named database, unique to this
checkout and invocation, and a separate schema file. The database account needs
permission to create and drop databases. Databases are dropped after each check,
including after failures and Ctrl+C. If the coordinator is forcibly killed or
the database server becomes unavailable, cleanup may need to be done manually;
the database names are in the check logs.

Without `DATABASE_URL`, workers use the test connection in `config/database.yml`.
With it, workers retain its connection settings and replace the database name.
For example, PostgreSQL checks migrate each new database instead of loading the
MySQL schema:

```sh
DATABASE_URL=postgresql://postgres@localhost/coplan_local_test bin/ci
```

Preview the selected worker counts and file counts without running commands:

```sh
bin/ci --list
```

Files are balanced by source size, separately for browser and non-browser specs.
Every discovered spec runs once. The coordinator prints each check's start,
finish, duration, and log path. Logs, RSpec JSON reports, private schema files,
and `summary.json` remain under the printed `tmp/local-ci/<run>/` directory.
An empty suite, a missing report, a failed audit, or a cleanup failure makes
`bin/ci` exit nonzero. Other checks finish so one failure does not hide their results.
Repeat a test order with `bin/ci --seed <printed-seed>`; keep the same worker
counts to preserve the same groups. GitHub's extra repeated regression cohorts
remain available separately through `bin/rspec-stress`.

## GitHub Actions

The workflow in `.github/workflows/ci.yml` runs these jobs independently:

| Job | Database | Runner | Coverage |
| --- | --- | --- | --- |
| Lint | None | `ubuntu-latest` | RuboCop |
| MySQL non-browser | MySQL | `ubuntu-x86-runners` | Every spec outside `spec/system/` |
| PostgreSQL non-browser | PostgreSQL | `ubuntu-x86-runners` | Every spec outside `spec/system/`, migration replay, reference seed idempotency |
| MySQL browser (four shards) | MySQL | `ubuntu-x86-runners` | Every spec in `spec/system/`, exactly once |
| MySQL browser stress (five repetitions) | MySQL | `ubuntu-x86-runners` | All four regression groups with a different seed in each job |

Block's [open-source CI guide](https://dev-guides.sqprod.co/docs/develop/open-source/guides/continuous-integration#larger-runners)
documents the larger runner pool as 16 CPUs, 64 GB RAM, and 600 GB disk. Ask OSPO in
`#opensource` if the repository cannot access the group.

Each job has its own database and, where needed, browser. A matrix failure cancels the remaining
jobs in that matrix to save runner time. Completed and failed jobs preserve their
reports and screenshots; cancelled jobs do not upload artifacts. A new
push to a PR cancels its superseded run. Main builds run independently.

Browser sharding sorts the discovered spec paths and distributes them round-robin.
New files are included automatically. The randomized stress groups keep their
files together to exercise cross-file cleanup. Each of the original five seeds
still runs once for each group, on MySQL. The separate voice cleanup check also
runs once in its original defined order.

## Run locally

Preview a browser shard without a database or Rails:

```sh
bin/rspec-system-shard 1 4 --list
```

Run that shard with the application's Ruby and bundle installed:

```sh
RAILS_ENV=test DATABASE_URL=mysql2://root@localhost/coplan_ci_local_test \
  bin/rails db:create db:schema:load
RAILS_ENV=test DATABASE_URL=mysql2://root@localhost/coplan_ci_local_test \
  bin/rspec-system-shard 1 4 --seed 123
```

Use a dedicated test database. Change the first number from 1 through 4 to try
each shard. Each invocation should run only its listed files and return nonzero
if any example fails.

Run the non-browser suite with either adapter's dedicated test database:

```sh
RAILS_ENV=test DATABASE_URL=mysql2://root@localhost/coplan_ci_local_test \
  bundle exec rspec --exclude-pattern 'spec/system/**/*_spec.rb' --seed 123
```

PostgreSQL CI creates its database with `db:create db:migrate`, sets
`SCHEMA=tmp/pg_schema.rb`, and invokes `coplan:seed` twice before running specs.
Use `?encoding=unicode` in its database URL to override the example host's
MySQL encoding. Actual runner availability and end-to-end timings must be checked
in GitHub Actions after publishing the workflow.
