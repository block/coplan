# GitHub CI

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
