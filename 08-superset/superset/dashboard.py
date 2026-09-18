"""Build the platform overview dashboard.

Idempotent: charts and the dashboard are matched by name, created if absent
and updated in place if present, so a chart someone has re-positioned keeps
its position and a re-run does not multiply anything.

---------------------------------------------------------------------------
 Why this is code rather than an exported bundle
---------------------------------------------------------------------------
 The documented path is to build a dashboard in the UI, export it as a zip of
 YAML, and import that at startup. It captures the layout exactly, which is
 the one thing that is genuinely tedious to write by hand.

 What it does not do is stay readable. An export is a machine artifact: a
 diff against it says which UUID changed, not which chart. Six months later
 nobody can tell from the file what the dashboard shows without importing it
 somewhere and looking.

 Here every chart is a dozen lines naming its dataset, its metric and its
 chart type. A reviewer can read what the dashboard is for. The cost is the
 layout, which is the fiddly part — see the note on position_json below.
---------------------------------------------------------------------------
"""
from __future__ import annotations

import json
import os
import sys
import textwrap

from superset.app import create_app

DATABASE_NAME = os.environ.get("SUPERSET_CLICKHOUSE_NAME", "ClickHouse marts")
SCHEMA = os.environ.get("CLICKHOUSE_MARTS_DB", "marts_marts")
DASHBOARD_TITLE = os.environ.get("SUPERSET_DASHBOARD_TITLE", "Platform overview")
DASHBOARD_SLUG = "platform-overview"


# ---------------------------------------------------------------------------
#  The charts
# ---------------------------------------------------------------------------
#  `params` is what the Explore UI would have produced. The keys are not
#  documented anywhere useful; they are what the viz plugin reads, and the
#  reliable way to discover them for a new chart type is to build one in the
#  UI and look at its params in the metadata database.
#
#  Metrics are referenced by name — they are defined once on the dataset in
#  datasets.py, so a chart inherits the definition rather than restating it.
#  Two charts that each define "revenue" will eventually disagree.
# ---------------------------------------------------------------------------
CHARTS: list[dict] = [
    {
        "name": "Revenue",
        "dataset": "daily_sales_by_category",
        "viz_type": "big_number_total",
        "width": 3,
        "height": 50,
        "params": {
            "metric": "revenue",
            "subheader": "all days, cancelled orders excluded",
            "y_axis_format": ",.0f",
        },
    },
    {
        "name": "Orders",
        "dataset": "daily_sales_by_category",
        "viz_type": "big_number_total",
        "width": 3,
        "height": 50,
        "params": {
            "metric": "orders",
            "y_axis_format": ",d",
        },
    },
    {
        "name": "Average order value",
        "dataset": "daily_sales_by_category",
        "viz_type": "big_number_total",
        "width": 3,
        "height": 50,
        "params": {
            # Computed from the sums, not averaged from a stored ratio — see
            # the metric definition. Averaging would weight a two-order day
            # the same as a two-thousand-order day.
            "metric": "avg_order_value",
            "y_axis_format": ",.2f",
        },
    },
    {
        "name": "Customers who have ordered",
        "dataset": "customer_order_summary",
        "viz_type": "big_number_total",
        "width": 3,
        "height": 50,
        "params": {
            "metric": "buyers",
            "subheader": "out of every customer on file",
            "y_axis_format": ",d",
        },
    },
    {
        "name": "Revenue by day",
        "dataset": "daily_sales_by_category",
        "viz_type": "echarts_timeseries_line",
        "width": 8,
        "height": 60,
        "params": {
            "x_axis": "day",
            "time_grain_sqla": "P1D",
            "metrics": ["revenue"],
            "groupby": [],
            "y_axis_format": ",.0f",
            "rich_tooltip": True,
            "show_legend": False,
        },
    },
    {
        "name": "Revenue by category",
        "dataset": "daily_sales_by_category",
        "viz_type": "pie",
        "width": 4,
        "height": 60,
        "params": {
            "groupby": ["category"],
            "metric": "revenue",
            "show_legend": True,
            "number_format": ",.0f",
        },
    },
    {
        "name": "Top customers",
        "dataset": "customer_order_summary",
        "viz_type": "table",
        "width": 6,
        "height": 60,
        "params": {
            "query_mode": "aggregate",
            "groupby": ["customer_id", "country_code"],
            "metrics": ["lifetime_value"],
            "row_limit": 25,
            "order_desc": True,
        },
    },
    {
        "name": "Warehouse against its source",
        "dataset": "recon_orders_by_source",
        "viz_type": "table",
        "width": 6,
        "height": 60,
        "params": {
            # The only chart here that is not about the business. It shows
            # whether the warehouse still matches the database it mirrors —
            # a question most dashboards cannot ask, because answering it
            # needs a second connection nobody set up.
            "query_mode": "raw",
            "all_columns": [
                "order_date", "pg_orders", "cdc_orders", "s3_orders",
                "cdc_minus_pg", "verdict",
            ],
            "order_by_cols": ['["order_date", false]'],
            "row_limit": 30,
        },
    },
]

# Which charts sit on which row, by name. Twelve columns to a row; the widths
# above have to add up to twelve or less per row.
ROWS: list[list[str]] = [
    ["Revenue", "Orders", "Average order value", "Customers who have ordered"],
    ["Revenue by day", "Revenue by category"],
    ["Top customers", "Warehouse against its source"],
]


def build_position(chart_ids: dict[str, int]) -> dict:
    """The layout, as Superset's dashboard grid expects it.

    This is the part an exported bundle would have given for free, and the
    reason the export path is tempting.

    The structure is a flat dictionary of nodes referencing each other by id,
    not a tree — every node also lists its ancestors in `parents`, and getting
    that list wrong produces a dashboard that loads with the charts stacked in
    a heap rather than an error.

    Widths are in twelfths. A row whose widths exceed twelve wraps in a way
    nobody intends.
    """
    position: dict = {
        "DASHBOARD_VERSION_KEY": "v2",
        "ROOT_ID": {"type": "ROOT", "id": "ROOT_ID", "children": ["GRID_ID"]},
        "GRID_ID": {
            "type": "GRID",
            "id": "GRID_ID",
            "children": [],
            "parents": ["ROOT_ID"],
        },
        "HEADER_ID": {
            "type": "HEADER",
            "id": "HEADER_ID",
            "meta": {"text": DASHBOARD_TITLE},
        },
    }

    for row_index, row in enumerate(ROWS, start=1):
        row_id = f"ROW-{row_index}"
        position["GRID_ID"]["children"].append(row_id)
        position[row_id] = {
            "type": "ROW",
            "id": row_id,
            "children": [],
            "parents": ["ROOT_ID", "GRID_ID"],
            "meta": {"background": "BACKGROUND_TRANSPARENT"},
        }

        for chart_name in row:
            spec = next(c for c in CHARTS if c["name"] == chart_name)
            chart_id = chart_ids[chart_name]
            node_id = f"CHART-{chart_id}"

            position[row_id]["children"].append(node_id)
            position[node_id] = {
                "type": "CHART",
                "id": node_id,
                "children": [],
                "parents": ["ROOT_ID", "GRID_ID", row_id],
                "meta": {
                    "chartId": chart_id,
                    "width": spec["width"],
                    "height": spec["height"],
                    "sliceName": chart_name,
                },
            }

    return position


def main() -> int:
    app = create_app()

    with app.app_context():
        from superset import db
        from superset.connectors.sqla.models import SqlaTable
        from superset.models.core import Database
        from superset.models.dashboard import Dashboard
        from superset.models.slice import Slice

        database = (
            db.session.query(Database)
            .filter_by(database_name=DATABASE_NAME)
            .one_or_none()
        )
        if database is None:
            print(f"no database named '{DATABASE_NAME}' — run register.sh first",
                  file=sys.stderr)
            return 1

        # ---- the charts ----------------------------------------------------
        chart_ids: dict[str, int] = {}

        for spec in CHARTS:
            dataset = (
                db.session.query(SqlaTable)
                .filter_by(
                    table_name=spec["dataset"],
                    schema=SCHEMA,
                    database_id=database.id,
                )
                .one_or_none()
            )
            if dataset is None:
                print(f"no dataset {SCHEMA}.{spec['dataset']} — run datasets.py first",
                      file=sys.stderr)
                return 1

            chart = (
                db.session.query(Slice)
                .filter_by(slice_name=spec["name"])
                .one_or_none()
            )
            if chart is None:
                chart = Slice(slice_name=spec["name"])
                db.session.add(chart)
                action = "created"
            else:
                action = "updated"

            chart.viz_type = spec["viz_type"]
            chart.datasource_type = "table"
            chart.datasource_id = dataset.id
            # params carries the dataset reference too. Setting one and not
            # the other gives a chart that opens on the right data and saves
            # against the wrong one.
            chart.params = json.dumps(
                {
                    **spec["params"],
                    "datasource": f"{dataset.id}__table",
                    "viz_type": spec["viz_type"],
                },
                indent=2,
            )

            # Needed before the id exists for the layout below.
            db.session.flush()
            chart_ids[spec["name"]] = chart.id
            print(f"  {action}: {spec['name']} ({spec['viz_type']})")

        # ---- the dashboard -------------------------------------------------
        dashboard = (
            db.session.query(Dashboard)
            .filter_by(slug=DASHBOARD_SLUG)
            .one_or_none()
        )
        if dashboard is None:
            dashboard = Dashboard(slug=DASHBOARD_SLUG)
            db.session.add(dashboard)
            action = "created"
        else:
            action = "updated"

        dashboard.dashboard_title = DASHBOARD_TITLE
        dashboard.published = True
        dashboard.slices = [
            db.session.query(Slice).get(i) for i in chart_ids.values()
        ]
        dashboard.position_json = json.dumps(build_position(chart_ids), indent=2)

        db.session.commit()
        print(f"  {action}: dashboard '{DASHBOARD_TITLE}' "
              f"({len(chart_ids)} charts in {len(ROWS)} rows)")

    print("dashboard built")
    return 0


if __name__ == "__main__":
    sys.exit(main())
