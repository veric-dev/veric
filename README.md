# veric

Catch dbt schema bugs before your pipeline runs. Single binary. Runs
locally. No warehouse queries executed.

You declared `email_preference` in a `.yml` six months ago. It's not in
the warehouse anymore — some migration dropped it — but the YAML still
references it, and three downstream models still select it. Tomorrow's
`dbt build` fails at runtime, halfway through a 40-minute DAG.

Or: your warehouse says `order_id` is `BIGINT`. Your dbt model declares
it as `Int32`. Both look fine individually. The first order ID above 2.1B
silently truncates and lands in your fact table with the wrong value.

These bugs are detectable from the compiled manifest and warehouse
catalog alone — no data movement, no queries run. veric catches them
statically, before `dbt build` ever starts.

```
$ veric check --manifest target/manifest.json --warehouse 'duckdb:///dev.db'

FAIL  jaffle_shop.stg_customers.email_preference
      phantom column: declared in dbt but not in warehouse
      declared:  models/staging/stg_customers.yml:14
      warehouse: (not found)

FAIL  jaffle_shop.orders.order_id
      type conflict: sources disagree
        warehouse:  BIGINT   (jaffle_shop.orders)
        dbt:        Int32    (models/marts/orders.yml:8)
      no common subtype — cast will truncate values > 2.1B

WARN  raw.payments.legacy_status
      dead column: in warehouse but no model references it

3 models verified
18/19 types resolved · 1 conflict
18 lineage edges traced · 1 phantom column · 1 dead column

exit 2 (schema problems found)
```

## How it compares

Every existing tool in the dbt data-quality stack catches problems at
runtime. The tools that do ship static analysis are locked inside dbt
Cloud Enterprise or require adopting a new framework.

| Tool | Static | Types | Lineage | Cross-source | Works with your dbt | License |
|---|---|---|---|---|---|---|
| dbt tests | runtime | — | — | — | ✓ | OSS |
| SQLFluff | syntactic | — | — | — | ✓ | OSS |
| dbt contracts | partial | declared | — | — | ✓ | OSS |
| SQLMesh | ✓ | partial | ✓ | — | needs migration | OSS |
| dbt Fusion | ✓ | ✓ | partial | — | dbt Cloud only | enterprise |
| **veric** | ✓ | ✓ | ✓ | ✓ | ✓ | closed, local |

The column that's empty everywhere except veric — **cross-source** —
is the differentiator. Every other tool checks one source. veric checks
the warehouse catalog against your dbt YAML against your DDL, and
surfaces the disagreement. That's where silent bugs live.

## Install

Download a pre-built binary from [Releases](https://github.com/veric-dev/veric/releases).

Single binary. No Python, no Node, no Docker, no runtime.

## What it does

Point veric at your dbt project and warehouse. One command, three
outputs, all computed in a single pass:

- **Cross-source type resolution**: warehouse says `BIGINT`, dbt says
  `integer`, DDL says `NUMBER(19)`. veric merges them with lattice-based
  type joins — resolving to a canonical type when sources agree,
  flagging a conflict when they don't. No silent coercions, no 2am cast
  failures.
- **Column-level lineage**: traces which source columns flow into which
  model columns, through SELECTs, JOINs, WHERE clauses, GROUP BYs,
  aggregations, and subqueries. Know exactly what breaks when an
  upstream column changes.
- **Schema validation**: detects phantom columns (in dbt but missing
  from the warehouse), dead columns (in the warehouse but never
  referenced), and type mismatches across sources.

These aren't three features bolted together. They're three views of the
same underlying analysis — a single tree walk that resolves every
column's type, origin, and consistency across all sources.

## Quick start

```bash
# 1. Compile your dbt project
cd my-dbt-project/
dbt compile

# 2. Verify against your warehouse
veric check --manifest target/manifest.json --warehouse 'duckdb:///path/to/dev.db'
```

When everything is clean:

```
  jaffle_shop.customers
    customer_id              Int64     ← stg_customers.customer_id
    first_name               Utf8      ← stg_customers.first_name
    first_order              Date      ← min(stg_orders.order_date)
    number_of_orders         Int64     ← count(stg_orders.order_id)
    customer_lifetime_value  Float64   ← sum(stg_payments.amount)

  4 models verified
  19/19 types resolved · 0 conflicts
  19 lineage edges traced · 0 phantom columns · 0 dead columns
```

Every line gives you the resolved type, the lineage origin, and
implicit validation — all at once. No warehouse queries executed.

### JSON output

```bash
veric check --manifest target/manifest.json --warehouse 'duckdb:///dev.db' --format json
```

Produces machine-readable JSON for piping into other tools:

```json
{
  "veric_version": "0.1.0",
  "schema_version": 1,
  "models": [
    {
      "fqn": "jaffle_shop.customers",
      "columns": [
        {
          "name": "customer_id",
          "type": "Int64",
          "sources": {
            "warehouse": "BIGINT",
            "dbt": "integer"
          },
          "lineage": [
            { "upstream": "jaffle_shop.stg_customers.customer_id", "transform": "direct" }
          ]
        }
      ]
    }
  ],
  "summary": {
    "models": 4,
    "columns_verified": 19,
    "types_resolved": 19,
    "type_conflicts": 0,
    "lineage_edges": 19,
    "phantom_columns": 0,
    "dead_columns": 0
  }
}
```

## Exit codes

veric follows Unix conventions so it can be used as a CI gate:

- `0` — clean, no issues
- `1` — runtime error (couldn't read manifest, couldn't connect to
  warehouse, parse failure)
- `2` — found schema problems (type conflicts, phantom columns, dead
  columns)

Use `veric check ... && echo "clean"` in CI to fail builds on schema
drift.

## Why an attribute grammar

veric is built on
[attribute grammars](https://en.wikipedia.org/wiki/Attribute_grammar) —
the same formalism behind compiler type checkers (rust-analyzer,
JastAdd, Silver). Each data source (warehouse catalog, dbt manifest,
DDL) produces a partial view of your schema as its own tree. A
canonical grammar merges them using **lattice-based type joins**: the
resolved type is the most specific type both sources agree on. When
sources disagree, the join hits top and veric flags a conflict — no
ad-hoc priority chains, no silent wins.

This matters for what comes next. Type resolution, lineage, and schema
validation are all attributes of the same tree nodes, computed in the
same pass. Adding a new check — grain analysis, NULL propagation, PII
tracking — is adding new attributes, not building a new tool.

## What's next

v0.1 catches type conflicts, lineage gaps, and schema inconsistencies.
The same engine will add deeper SQL analysis — each is a new attribute
on the same tree:

- **Grain / fan-out detection** — catch joins that silently multiply
  rows before your SUMs are 3x too high
- **NULL propagation** — trace where LEFT JOINs introduce NULLs into
  columns that downstream models assume are non-null
- **Snowflake and BigQuery** warehouse support
- **Richer SQL coverage** (CTEs, window functions, UNION, LATERAL)
- **Governance rules** — PII propagation, classifier inheritance
  through lineage
- **MCP server** for AI coding assistant integration
- **Watch mode** for continuous verification during development

## Privacy

veric runs entirely locally. It does not phone home, does not collect
telemetry, and does not require any account. Your schema and your data
stay on your machine. If that ever changes, it will be opt-in and
documented here.

## Source availability

veric is a closed-source binary for v0.1. No source available, no
contributions yet. This may change — see the roadmap. In the meantime:
the binary runs locally, touches no network, and can be inspected with
standard tooling.

## Current limitations

v0.1 is honest about its rough edges:

- **DuckDB only** for warehouse connections. Snowflake and BigQuery are
  the immediate next targets.
- **Basic SQL patterns**: SELECT, JOIN, WHERE, GROUP BY, subqueries.
  CTEs and window functions are partial. Complex Jinja is not analyzed.
- **dbt v1.7+** required (reads `manifest.json` from `dbt compile`).
- **No incremental mode** yet — re-checks the full project each run.
- **v0.x is pre-stable.** CLI surface and JSON output schema may change
  between minor versions.

## License

Proprietary. All rights reserved.
