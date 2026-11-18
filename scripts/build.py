"""Загрузка CSV в SQLite и выгрузка результатов SQL."""

import argparse
import csv
import json
from pathlib import Path
import sqlite3
from tempfile import TemporaryDirectory


PROJECT = Path(__file__).resolve().parents[1]

# Порядок полей совпадает со схемой в 01_source.sql.
SOURCES = {
    "raw_orders": (
        "olist_orders_dataset.csv",
        ("order_id", "customer_id", "order_status", "order_purchase_timestamp",
         "order_delivered_customer_date", "order_estimated_delivery_date"),
    ),
    "raw_customers": (
        "olist_customers_dataset.csv", ("customer_id", "customer_state"),
    ),
    "raw_items": (
        "olist_order_items_dataset.csv", ("order_id", "order_item_id", "product_id", "seller_id"),
    ),
    "raw_products": (
        "olist_products_dataset.csv", ("product_id", "product_category_name"),
    ),
    "raw_categories": (
        "product_category_name_translation.csv",
        ("product_category_name", "product_category_name_english"),
    ),
    "raw_reviews": (
        "olist_order_reviews_dataset.csv",
        ("review_id", "order_id", "review_score", "review_creation_date", "review_answer_timestamp"),
    ),
    "raw_sellers": (
        "olist_sellers_dataset.csv", ("seller_id", "seller_state"),
    ),
}

EXPORTS = {
    "summary": "SELECT * FROM v_summary",
    "severity": "SELECT * FROM v_severity ORDER BY bucket_order",
    "monthly": "SELECT * FROM v_monthly ORDER BY month",
    "priority_queue": "SELECT * FROM v_priority_queue ORDER BY segment_type, priority",
    "priority_routes": """
        SELECT * FROM v_top_segment_routes
        ORDER BY late_low DESC, delivered DESC, seller_state
    """,
    "quality_checks": "SELECT * FROM v_checks ORDER BY check_name",
    "coverage": "SELECT * FROM v_coverage ORDER BY metric",
}

DASHBOARD_QUERIES = {
    "summary": EXPORTS["summary"],
    "severity": EXPORTS["severity"],
    "monthly": EXPORTS["monthly"],
    "severity_by_state": "SELECT * FROM v_severity_by_state ORDER BY state, bucket_order",
    "monthly_by_state": "SELECT * FROM v_monthly_by_state ORDER BY state, month",
    "segments": """
        SELECT * FROM v_segments ORDER BY segment_type, late_low DESC, delivered DESC, segment
    """,
}


def load_sources(connection, source_dir):
    for table, (filename, columns) in SOURCES.items():
        with (source_dir / filename).open(encoding="utf-8-sig", newline="") as source:
            reader = csv.DictReader(source)
            missing = set(columns).difference(reader.fieldnames or ())
            if missing:
                raise ValueError(f"{filename}: missing columns {', '.join(sorted(missing))}")
            placeholders = ", ".join("?" for _ in columns)
            rows = (tuple(row[column] or None for column in columns) for row in reader)
            connection.executemany(f"INSERT INTO {table} VALUES ({placeholders})", rows)


def write_results(connection, stage):
    for name, query in EXPORTS.items():
        cursor = connection.execute(query)
        with (stage / f"{name}.csv").open("w", encoding="utf-8-sig", newline="") as target:
            writer = csv.writer(target)
            writer.writerow([column[0] for column in cursor.description])
            writer.writerows(cursor)

    data = {}
    for name, query in DASHBOARD_QUERIES.items():
        data[name] = [dict(row) for row in connection.execute(query)]
    data["summary"] = data["summary"][0]
    (stage / "dashboard-data.json").write_text(
        json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False) + "\n",
        encoding="utf-8",
    )


def build(source_dir):
    missing = [filename for filename, _ in SOURCES.values() if not (source_dir / filename).is_file()]
    if missing:
        raise FileNotFoundError(f"{source_dir}: missing CSV files: {', '.join(missing)}")

    results = PROJECT / "results"
    dashboard = PROJECT / "dashboard"
    results.mkdir(exist_ok=True)
    dashboard.mkdir(exist_ok=True)

    with TemporaryDirectory(prefix="olist-build-", dir=PROJECT) as temp_dir:
        stage = Path(temp_dir)
        database = stage / "olist.sqlite"
        connection = sqlite3.connect(database)
        connection.row_factory = sqlite3.Row
        try:
            connection.executescript((PROJECT / "sql/01_source.sql").read_text(encoding="utf-8"))
            with connection:
                load_sources(connection, source_dir)

            for filename in ("02_order_mart.sql", "03_analysis.sql", "04_quality_checks.sql"):
                connection.executescript((PROJECT / "sql" / filename).read_text(encoding="utf-8"))

            failures = list(connection.execute("SELECT * FROM v_checks WHERE ok IS NOT 1"))
            if failures:
                details = [f"{r['check_name']}: {r['actual']} (expected {r['expected']})" for r in failures]
                raise RuntimeError("SQL checks failed: " + "; ".join(details))

            write_results(connection, stage)
        finally:
            connection.close()

        database.replace(PROJECT / "olist.sqlite")
        for name in EXPORTS:
            (stage / f"{name}.csv").replace(results / f"{name}.csv")
        (stage / "dashboard-data.json").replace(dashboard / "dashboard-data.json")

    print(f"SQLite database: {PROJECT / 'olist.sqlite'}")
    print(f"SQL exports: {results}")
    print("All SQL data checks passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", required=True, type=Path, help="Directory with the Olist CSV files")
    args = parser.parse_args()
    build(args.data_dir)


if __name__ == "__main__":
    main()
