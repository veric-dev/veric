# veric

Static analysis for your data warehouse. Catches schema problems before
your pipeline runs. Written in Rust.

Every data quality tool you have — dbt tests, Monte Carlo, Great
Expectations — catches problems *after* the pipeline runs. After the
compute. After the wrong numbers land in the dashboard. After the Slack
thread from the CFO.

A join silently triples your revenue because nobody checked the grain.
A LEFT JOIN injects NULLs into a column that downstream models assume
is non-null. Your warehouse says `BIGINT`, dbt says `integer`, and
you find out when a cast fails at 2am. These aren't edge cases — they're
the most common data bugs, and no existing tool catches them before
execution.

veric is a static analyzer for dbt projects. It reads your compiled
manifest and warehouse catalog at compile time — no data touched, no
queries run — and catches type conflicts, lineage gaps, and schema
inconsistencies before you deploy.

## What it does

Point veric at your dbt project and warehouse. One command, one pass,
three outputs:

- **Cross-source type resolution**: your warehouse says `BIGINT`, dbt
  says `integer`, your DDL says `NUMBER(19)`. veric merges them using
  lattice-based type joins — resolving to a canonical type when sources
  agree, flagging a conflict when they don't. No silent coercions, no
  runtime cast failures.
- **Column-level lineage**: traces which source columns flow into which
  model columns, through SELECTs, JOINs, WHERE clauses, GROUP BYs,
  aggregations, and subqueries. Know exactly what breaks when an
  upstream column changes.
- **Schema validation**: detects phantom columns (declared in dbt but
  missing from the warehouse), dead columns (in the warehouse but never
  referenced), and type mismatches — before they become production
  incidents.

These aren't separate features bolted together. They're three views of
the same underlying analysis — a single tree walk that resolves every
column's type, origin, and consistency across all sources simultaneously.

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
    status           Utf8      ← raw.orders.status

  jaffle_shop.stg_payments
    payment_id       Int64     ← raw.payments.id
    order_id         Int64     ← raw.payments.order_id
    payment_method   Utf8      ← raw.payments.method
    amount           Float64   ← raw.payments.amount

  jaffle_shop.customers
    customer_id              Int64     ← stg_customers.customer_id
    first_name               Utf8      ← stg_customers.first_name
    last_name                Utf8      ← stg_customers.last_name
    first_order              Date      ← min(stg_orders.order_date)
    most_recent_order        Date      ← max(stg_orders.order_date)
    number_of_orders         Int64     ← count(stg_orders.order_id)
    customer_lifetime_value  Float64   ← sum(stg_payments.amount)

  jaffle_shop.orders
    order_id         Int64     ← stg_orders.order_id
    customer_id      Int64     ← stg_orders.customer_id
    order_date       Date      ← stg_orders.order_date
    status           Utf8      ← stg_orders.status
    amount           Float64   ← sum(stg_payments.amount)

  4 models verified
  19/19 types resolved · 0 conflicts
  19 lineage edges traced
  0 phantom columns · 0 dead columns
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

- `0` — verification passed, no issues
- `1` — runtime error (couldn't read manifest, couldn't connect to
  warehouse, parse failure)
- `2` — verification completed but found problems (type conflicts,
  phantom columns, dead columns)

Use `veric check ... && echo "clean"` in CI to fail builds on schema
drift.

## Why static analysis

Every data quality tool in the dbt ecosystem today is **runtime** — it
checks data *after* the pipeline executes. dbt tests run post-build.
Monte Carlo monitors post-landing. Great Expectations validates
post-load. You pay for the compute, then find out something is wrong.

Static analysis is categorically different. veric analyzes your project
at compile time — before any SQL runs, before any warehouse credits are
spent, before any data moves. The same way a type checker catches bugs
in your code before you ship it.

This isn't a new idea. Compilers have done it for decades. IDE features
like "go to definition," type inference, and error highlighting all use
static analysis. dbt Labs acquired SDF Labs specifically to bring SQL
static analysis into dbt Fusion. The entire industry is converging on
"understand SQL semantically before running it."

veric is built on the same formalism that powers those compilers:
[attribute grammars](https://en.wikipedia.org/wiki/Attribute_grammar).
Each data source (warehouse catalog, dbt manifest, DDL) produces a
partial view of your schema as its own tree. A canonical grammar merges
them using **lattice-based type joins**: the resolved type is the most
specific type both sources agree on. When sources genuinely disagree,
the join hits top and veric flags a conflict — no ad-hoc priority
chains, no silent wins, no surprises.

This architecture means new analyses come cheap. Type resolution,
lineage, and schema validation are all attributes of the same tree
nodes, computed in the same pass. Adding a new check — grain analysis,
NULL propagation, PII tracking — is adding new attributes, not building
a new tool.

## What's next

v0.1 catches type conflicts, lineage gaps, and schema inconsistencies.
The same engine will add deeper SQL analysis — each is a new attribute
on the same tree, not a new architecture:

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
