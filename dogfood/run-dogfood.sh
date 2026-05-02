#!/usr/bin/env bash
# Dogfood verification harness for v0.1 launch.
#
# Per `mvp-free-tier-scope-2026-05.md` § Success criteria #6, the
# launch gate requires "the brew → scan (with warehouse consent) →
# signup → push loop has been walked end-to-end by 3 real users
# (not the founder) from cold, on their own machines, on their own
# projects".
#
# This script does NOT replace those three real-user runs — only a
# human can give us the UX-gap data they're meant to surface. What
# it DOES do is provide a deterministic, scriptable proxy that:
#
#   1. Walks the same steps a cold user would (brew install → init
#      → scan → push) but against three known dbt projects.
#   2. Captures stdout/stderr + exit codes per step.
#   3. Surfaces obvious failures (parse errors, panics, exit≠0)
#      before we ask a real user to hit them.
#   4. Generates a report at `dogfood/report-$(date +%Y%m%d).md`
#      that the human dogfooders can fill in with subjective UX
#      notes, then attached to the launch checklist.
#
# Three target projects:
#   1. jaffle_shop          — canonical dbt example (DuckDB)
#   2. telemetry-dbt        — internal Snowflake project (set
#                             VERIC_DOGFOOD_SNOWFLAKE_PROFILE)
#   3. dbt-utils-integration-tests — third-party project, exercises
#                             cross-project lineage edges
#
# Override projects via DOGFOOD_PROJECT_DIRS as a colon-separated
# list of absolute paths.

set -euo pipefail

VERIC_BIN="${VERIC_BIN:-veric}"
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_DIR="$(cd "$(dirname "$0")" && pwd)/reports"
REPORT_FILE="${REPORT_DIR}/dogfood-${RUN_TS}.md"
mkdir -p "$REPORT_DIR"

DEFAULT_PROJECTS="${HOME}/dev/jaffle_shop:${HOME}/dev/telemetry-dbt:${HOME}/dev/dbt-utils-integration-tests"
PROJECTS="${DOGFOOD_PROJECT_DIRS:-$DEFAULT_PROJECTS}"

# Always opt out of telemetry during dogfood — we don't want
# rehearsal traffic mixed with prod.
export VERIC_NO_TELEMETRY=1

log() { printf '[dogfood] %s\n' "$*" >&2; }

write_header() {
    cat > "$REPORT_FILE" <<EOF
# Dogfood report — $RUN_TS

Veric binary: \`$($VERIC_BIN --version 2>&1 || echo "MISSING")\`
Driver script: \`$(realpath "$0")\`
Telemetry: OFF (\`VERIC_NO_TELEMETRY=1\`)

| project | init exit | scan exit | findings | UX notes |
|---------|-----------|-----------|----------|----------|
EOF
}

run_one_project() {
    local proj_dir="$1"
    local proj_name
    proj_name="$(basename "$proj_dir")"

    if [ ! -d "$proj_dir" ]; then
        log "SKIP $proj_name — directory does not exist: $proj_dir"
        echo "| $proj_name | SKIP | SKIP | n/a | not present at $proj_dir |" >> "$REPORT_FILE"
        return 0
    fi

    log "=== $proj_name ($proj_dir) ==="

    local work
    work="$(mktemp -d "/tmp/veric-dogfood-${proj_name}-XXXXXX")"
    cp -R "$proj_dir/." "$work/"

    pushd "$work" >/dev/null

    # Step 1: init
    local init_log="${REPORT_DIR}/${proj_name}-${RUN_TS}-init.log"
    local init_exit=0
    "$VERIC_BIN" init >"$init_log" 2>&1 || init_exit=$?
    log "init exit=$init_exit (log: $init_log)"

    # Step 2: scan in dry-run mode (no SaaS push during dogfood)
    local scan_log="${REPORT_DIR}/${proj_name}-${RUN_TS}-scan.log"
    local scan_exit=0
    "$VERIC_BIN" scan \
        --policy workspace.yml \
        --workspace-id 00000000-0000-0000-0000-000000000000 \
        --project-hash "dogfood-$proj_name" \
        --no-git \
        --dry-run \
        >"$scan_log" 2>&1 || scan_exit=$?
    log "scan exit=$scan_exit (log: $scan_log)"

    # Crude finding count — the dry-run output prints SARIF; count
    # `"ruleId":` occurrences. Real launch will cross-reference
    # against the analyser's structured count.
    local findings
    findings="$(grep -c '"ruleId"' "$scan_log" 2>/dev/null || echo 0)"

    echo "| $proj_name | $init_exit | $scan_exit | $findings | (fill in by hand) |" >> "$REPORT_FILE"

    popd >/dev/null
    rm -rf "$work"
}

main() {
    if ! command -v "$VERIC_BIN" >/dev/null 2>&1; then
        echo "fatal: \`$VERIC_BIN\` not on PATH — install via brew tap first" >&2
        exit 1
    fi

    write_header

    local IFS=:
    for proj in $PROJECTS; do
        run_one_project "$proj"
    done

    cat >> "$REPORT_FILE" <<EOF

## Per-run logs

Logs for each project's init + scan steps are alongside this report
as \`<project>-${RUN_TS}-{init,scan}.log\`.

## UX notes (fill in)

For each project, the human dogfooder should note:

- Did the binary install cleanly via \`brew install veric-dev/tap/veric\`?
- Did \`veric init\` produce a workspace.yml that ran without edits?
- Did \`veric scan\` produce findings the user understood without docs?
- Were any findings false positives? Note rule + reason.
- Were any errors / panics / unclear messages encountered? Pin them
  here with the exact stderr text.

Three dogfood runs by non-founders are the launch gate per
\`mvp-free-tier-scope-2026-05.md\` § Success criteria #6.
EOF

    log "Report written to $REPORT_FILE"
}

main "$@"
