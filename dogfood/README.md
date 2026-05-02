# Dogfood verification

Per `mvp-free-tier-scope-2026-05.md` § Success criteria #6, three
real-user runs (not the founder) are the launch gate.

This directory holds the scriptable proxy that surfaces the obvious
crashes/parse-errors before we ask a real user to trip over them,
plus the report skeleton each human dogfooder fills in.

## Run

```sh
# Default: jaffle_shop, telemetry-dbt, dbt-utils-integration-tests
./run-dogfood.sh

# Override target projects
DOGFOOD_PROJECT_DIRS=/path/a:/path/b:/path/c ./run-dogfood.sh

# Use a non-PATH binary (e.g. testing a release tarball pre-publish)
VERIC_BIN=/tmp/veric-0.1.0/veric ./run-dogfood.sh
```

Reports land in `dogfood/reports/dogfood-<TIMESTAMP>.md`. The human
dogfooder is expected to (a) walk the brew → init → scan → push
loop on their own machine, and (b) fill in the **UX notes** column
with prose.

## Why this is not a substitute for real users

The script runs the same commands a cold user would, but it can't
tell us:

- Whether the SARIF findings make sense to a human reading them.
- Whether the warehouse-consent prompt feels invasive.
- Whether `veric init` produces a config the user understands.
- Whether the README / install instructions are followable from
  cold.

Three real users = the only signal that matters for the launch
gate. The script is verification scaffolding so we don't waste
those three users on bugs we could have caught locally.
