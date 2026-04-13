# veric

Schema verification for your data warehouse. Written in Rust.

Your warehouse catalog, your dbt YAML, and your DDL files all describe
the same columns — and they disagree. Your warehouse says `BIGINT`, dbt
says `integer`, your DDL says `NUMBER(19)`. A column exists in dbt but
not in the warehouse. A source column feeds three downstream models
through two transforms, but nothing tracks that.

These aren't three separate problems. They're the same problem: no
single source of truth about your schema.

veric solves it once. Point it at your dbt project and warehouse — get
resolved types, column-level lineage, and schema validation in a single
pass.

## What it does

- **Cross-source type resolution**: your warehouse, dbt manifest, and DDL
  each report column types differently. veric merges them using
  lattice-based type joins — resolving to a canonical type when sources
  agree, flagging a conflict when they don't.
- **Column-level lineage**: traces which source columns flow into which
  model columns, through SELECTs, JOINs, WHERE clauses, GROUP BYs,
  aggregations, and subqueries.
- **Schema validation**: detects phantom columns (declared in dbt but
  missing from the warehouse), dead columns (in the warehouse but never
  referenced), and type mismatches across sources — before they become
  production incidents.

These aren't separate features. They're three views of the same
underlying analysis — a single tree walk that resolves every column's
type, origin, and consistency across all sources simultaneously.

## Install

Download a pre-built binary from [Releases](https://github.com/veric-dev/veric/releases).

## Quick start

```bash
# 1. Compile your dbt project (generates target/manifest.json)
cd my-dbt-project/
dbt compile

# 2. Verify the project against your warehouse
veric check --manifest target/manifest.json --warehouse 'duckdb:///path/to/dev.db'
```

Output:

```
  jaffle_shop.stg_orders
    order_id         Int64     ← raw.orders.id
    customer_id      Int64     ← raw.orders.user_id
    order_date       Date      ← raw.orders.order_date
    status           Utf8     ← raw.orders.status

  jaffle_shop.stg_payments
    payment_id       Int64     ← raw.payments.id
    order_id         Int64     ← raw.payments.order_id
    payment_method   Utf8     ← raw.payments.method
    amount           Float64   ← raw.payments.amount

  jaffle_shop.customers
    customer_id              Int64     ← stg_customers.customer_id
    first_name               Utf8     ← stg_customers.first_name
    last_name                Utf8     ← stg_customers.last_name
    first_order              Date      ← min(stg_orders.order_date)
    most_recent_order        Date      ← max(stg_orders.order_date)
    number_of_orders         Int64     ← count(stg_orders.order_id)
    customer_lifetime_value  Float64   ← sum(stg_payments.amount)

  jaffle_shop.orders
    order_id         Int64     ← stg_orders.order_id
    customer_id      Int64     ← stg_orders.customer_id
    order_date       Date      ← stg_orders.order_date
    status           Utf8     ← stg_orders.status
    amount           Float64   ← sum(stg_payments.amount)

  4 models verified
  19/19 types resolved · 0 conflicts
  19 lineage edges traced
  0 phantom columns · 0 dead columns
```

Every line gives you all three at once: the resolved type, the lineage
origin, and implicit validation (any conflict or phantom would surface
here).

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

- `0` — verification passed, no issues
- `1` — runtime error (couldn't read manifest, couldn't connect to
  warehouse, parse failure)
- `2` — verification completed but found problems (type conflicts,
  phantom columns, dead columns)

Use `veric check ... && echo "clean"` in CI to fail builds on schema
drift.

## How it works

Most tools treat lineage and type checking as separate problems —
different tools, different data models, different passes over your
schema. veric treats them as one.

The insight: your data warehouse is a tree. Workspaces contain projects,
projects contain tables, tables contain columns. Each node in this tree
has **attributes** — computed properties that depend on the node's
children, its parent, and references to other nodes. A column's resolved
type, its upstream lineage, and its validation status are all just
attributes of the same node, computed in the same pass.

veric implements this using an
[attribute grammar](https://en.wikipedia.org/wiki/Attribute_grammar) —
the same formalism that powers compilers and type checkers (rust-analyzer,
JastAdd, Silver). Each data source (warehouse catalog, dbt manifest, DDL)
produces a partial view of your schema as its own tree. A canonical
grammar merges them using **lattice-based type joins**: the resolved type
is the most specific type both sources agree on. When sources genuinely
disagree, the join hits top and veric flags a conflict — no ad-hoc
priority chains, no silent wins, no data-loss surprises.

This architecture has two practical consequences:

**Adding a source doesn't change existing logic.** Want to add Snowflake
tags as a source? Write a parser that produces a new tree, register it,
and the lattice merges it in. Existing resolution equations are
untouched.

**New analysis capabilities come cheap.** Lineage, type resolution, and
schema validation emerged from the same framework. PII propagation,
classifier inheritance, and governance rules are next — same tree, new
attributes, no new architecture.

## Privacy

veric runs entirely locally. It does not phone home, does not collect
telemetry, and does not require any account. Your schema and your data
stay on your machine. If that ever changes, it will be opt-in and
documented here.

## Current limitations

v0.1 is honest about its rough edges:

- **DuckDB only** for warehouse connections. Snowflake and BigQuery are
  the immediate next targets.
- **Basic SQL patterns**: SELECT, JOIN, WHERE, GROUP BY, subqueries. CTEs
  and window functions are partial. Complex Jinja is not analyzed.
- **dbt v1.7+** required (reads `manifest.json` from `dbt compile`).
- **No incremental mode** yet — re-checks the full project each run.
- **v0.x is pre-stable.** CLI surface and JSON output schema may change
  between minor versions.

## What's next

- Snowflake and BigQuery warehouse support
- Richer SQL coverage (CTEs, window functions, UNION, LATERAL)
- Type inference from SQL expressions — pick up types from the query
  itself, not just from declarations
- Governance rules (PII propagation, classifier inheritance through
  lineage)
- MCP server for AI coding assistant integration
- Watch mode for continuous verification during development

## License

Proprietary. All rights reserved.
