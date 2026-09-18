"""Register the dbt marts as Superset datasets.

Idempotent: run it as often as you like. A dataset that already exists is left
alone apart from its metrics, which are reconciled.

---------------------------------------------------------------------------
 Why a script rather than the YAML bundle Superset documents
---------------------------------------------------------------------------
 The supported file-based path is `superset import-datasources` with a zip of
 YAML. It carries column definitions, metric definitions, and a UUID linking
 each dataset to the database it reads. That UUID is generated when the
 database is registered, so a bundle exported from one installation points at
 a database that does not exist in another — and the import succeeds anyway,
 producing datasets attached to nothing.

 That failure is invisible until someone opens a chart. This script looks the
 database up by name instead, which cannot silently miss, and raises if it is
 absent.

 The trade: this uses Superset's internal models, which are not a stable API
 and may need adjusting on a major upgrade. The smoke test is what turns that
 into a red build rather than a surprise.
---------------------------------------------------------------------------
"""
from __future__ import annotations

import os
import sys

from superset.app import create_app

DATABASE_NAME = os.environ.get("SUPERSET_CLICKHOUSE_NAME", "ClickHouse marts")
SCHEMA = os.environ.get("CLICKHOUSE_MARTS_DB", "marts_marts")


# ---------------------------------------------------------------------------
#  What to register, and what each one is for
# ---------------------------------------------------------------------------
#  Only the marts. The staging models are views over change-capture tables
#  with FINAL applied — correct to read, expensive to read repeatedly, and not
#  what a dashboard should be pointed at.
#
#  Metrics are defined here rather than left to whoever builds a chart. A
#  metric defined in a chart is invisible to every other chart, and two charts
#  that each define "revenue" will eventually disagree. Defined on the dataset,
#  there is one definition and every chart inherits it.
# ---------------------------------------------------------------------------
DATASETS: list[dict] = [
    {
        "table": "daily_sales_by_category",
        "description": (
            "Revenue per day and category, excluding cancelled orders. Built "
            "by dbt; the same numbers the hand-written job in 04-etl produces."
        ),
        "main_dttm": "day",
        "metrics": [
            {
                "metric_name": "revenue",
                "verbose_name": "Revenue",
                "expression": "SUM(revenue)",
                "d3format": ",.2f",
                "description": "Excludes cancelled orders.",
            },
            {
                "metric_name": "orders",
                "verbose_name": "Orders",
                "expression": "SUM(orders)",
                "d3format": ",d",
            },
            {
                "metric_name": "items",
                "verbose_name": "Items sold",
                "expression": "SUM(items)",
                "d3format": ",d",
            },
            {
                # Derived rather than stored, because a ratio cannot be summed.
                # Averaging a stored per-row ratio would weight a day with two
                # orders the same as a day with two thousand.
                "metric_name": "avg_order_value",
                "verbose_name": "Average order value",
                "expression": "SUM(revenue) / NULLIF(SUM(orders), 0)",
                "d3format": ",.2f",
                "description": "Computed from the sums, not averaged from a ratio.",
            },
        ],
    },
    {
        "table": "customer_order_summary",
        "description": (
            "One row per customer with their order history. Customers who "
            "have never ordered appear with zeros."
        ),
        "main_dttm": None,
        "metrics": [
            {
                "metric_name": "customers",
                "verbose_name": "Customers",
                "expression": "COUNT(*)",
                "d3format": ",d",
            },
            {
                "metric_name": "lifetime_value",
                "verbose_name": "Lifetime value",
                "expression": "SUM(lifetime_value)",
                "d3format": ",.2f",
            },
            {
                "metric_name": "buyers",
                "verbose_name": "Customers who have ordered",
                "expression": "COUNT(CASE WHEN orders_placed > 0 THEN 1 END)",
                "d3format": ",d",
                "description": (
                    "Distinct from the customer count: the gap is the group "
                    "worth looking at."
                ),
            },
        ],
    },
    {
        "table": "recon_orders_by_source",
        "description": (
            "Order counts per day across three routes: Postgres read live, "
            "the CDC staging layer, and the Parquet Spark wrote. The only "
            "model that checks the warehouse against its source."
        ),
        "main_dttm": "order_date",
        "metrics": [
            {
                "metric_name": "days_checked",
                "verbose_name": "Days checked",
                "expression": "COUNT(*)",
                "d3format": ",d",
            },
            {
                "metric_name": "days_diverged",
                "verbose_name": "Days diverged",
                "expression": "COUNT(CASE WHEN verdict = 'DIVERGED' THEN 1 END)",
                "d3format": ",d",
                "description": "Anything above zero deserves a look.",
            },
        ],
    },
]


def main() -> int:
    app = create_app()

    with app.app_context():
        from superset import db
        from superset.connectors.sqla.models import SqlaTable, SqlMetric
        from superset.models.core import Database

        database = (
            db.session.query(Database)
            .filter_by(database_name=DATABASE_NAME)
            .one_or_none()
        )
        if database is None:
            # Loud rather than silent. The YAML import path would have created
            # datasets attached to a database that does not exist, and said
            # nothing until someone opened a chart.
            print(
                f"no database named '{DATABASE_NAME}' — run provision.sh first",
                file=sys.stderr,
            )
            return 1

        for spec in DATASETS:
            table_name = spec["table"]

            dataset = (
                db.session.query(SqlaTable)
                .filter_by(
                    table_name=table_name,
                    schema=SCHEMA,
                    database_id=database.id,
                )
                .one_or_none()
            )

            if dataset is None:
                dataset = SqlaTable(
                    table_name=table_name,
                    schema=SCHEMA,
                    database=database,
                )
                db.session.add(dataset)
                action = "created"
            else:
                action = "updated"

            dataset.description = spec["description"]
            if spec["main_dttm"]:
                dataset.main_dttm_col = spec["main_dttm"]

            # Ask ClickHouse what the columns are rather than declaring them.
            # A hand-written column list drifts the moment a model changes, and
            # the drift shows up as a column missing from a chart rather than
            # as an error here.
            dataset.fetch_metadata()

            # Metrics are reconciled by name: existing ones are updated in
            # place so charts keep working, and new ones are added. Nothing is
            # removed — a metric someone added in the UI is theirs, and
            # deleting it would break their chart to enforce a file.
            existing = {m.metric_name: m for m in dataset.metrics}
            for m in spec["metrics"]:
                metric = existing.get(m["metric_name"])
                if metric is None:
                    metric = SqlMetric(metric_name=m["metric_name"])
                    dataset.metrics.append(metric)
                metric.expression = m["expression"]
                metric.verbose_name = m.get("verbose_name")
                metric.d3format = m.get("d3format")
                metric.description = m.get("description")

            print(f"  {action}: {SCHEMA}.{table_name} "
                  f"({len(dataset.columns)} columns, {len(spec['metrics'])} metrics)")

        db.session.commit()

    print("datasets registered")
    return 0


if __name__ == "__main__":
    sys.exit(main())
