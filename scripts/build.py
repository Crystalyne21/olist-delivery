"""Загрузка CSV в PostgreSQL через psql и выгрузка результатов SQL."""

import argparse
import csv
import json
from pathlib import Path
import shutil
import subprocess
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


def prepare_sources(source_dir, stage):
    for table, (filename, columns) in SOURCES.items():
        with (
            (source_dir / filename).open(encoding="utf-8-sig", newline="") as source,
            (stage / f"{table}.csv").open("w", encoding="utf-8", newline="") as target,
        ):
            reader = csv.DictReader(source)
            missing = set(columns).difference(reader.fieldnames or ())
            if missing:
                raise ValueError(f"{filename}: missing columns {', '.join(sorted(missing))}")
            writer = csv.writer(target)
            writer.writerows(tuple(row[column] for column in columns) for row in reader)


def run_sql(psql, connection_options, stage):
    sql_files = PROJECT / "sql"
    program = [
        r"\encoding UTF8",
        "SET client_min_messages TO warning;",
        "SET DateStyle TO 'ISO, YMD';",
        (sql_files / "01_source.sql").read_text(encoding="utf-8"),
    ]
    for table in SOURCES:
        program.append(rf"\copy {table} FROM '{table}.csv' WITH (FORMAT csv, ENCODING 'UTF8')")
    program.append("ANALYZE " + ", ".join(SOURCES) + ";")
    for filename in ("02_order_mart.sql", "03_analysis.sql", "04_quality_checks.sql"):
        program.append((sql_files / filename).read_text(encoding="utf-8"))

    for name, query in (EXPORTS | DASHBOARD_QUERIES).items():
        program.extend([
            rf"\o {name}.json",
            f"SELECT COALESCE(json_agg(result), '[]'::json) FROM ({query}) AS result;",
            r"\o",
        ])

    (stage / "build.sql").write_text("\n".join(program) + "\n", encoding="utf-8")
    command = [
        psql, "-X", "--quiet", "--no-align", "--tuples-only", "--single-transaction",
        "--set=ON_ERROR_STOP=1", *connection_options, "--file=build.sql",
    ]
    try:
        subprocess.run(command, cwd=stage, check=True)
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"PostgreSQL: psql завершился с кодом {error.returncode}.") from None


def write_results(stage):
    data = {
        name: json.loads((stage / f"{name}.json").read_text(encoding="utf-8"))
        for name in EXPORTS | DASHBOARD_QUERIES
    }
    for name in EXPORTS:
        rows = data[name]
        with (stage / f"{name}.csv").open("w", encoding="utf-8-sig", newline="") as target:
            if rows:
                writer = csv.DictWriter(target, fieldnames=list(rows[0]))
                writer.writeheader()
                writer.writerows(rows)

    snapshot = {name: data[name] for name in DASHBOARD_QUERIES}
    snapshot["summary"] = snapshot["summary"][0]
    (stage / "dashboard-data.json").write_text(
        json.dumps(snapshot, ensure_ascii=False, indent=2, allow_nan=False) + "\n",
        encoding="utf-8",
    )


def build(source_dir, psql, connection_options):
    missing = [filename for filename, _ in SOURCES.values() if not (source_dir / filename).is_file()]
    if missing:
        raise FileNotFoundError(f"{source_dir}: missing CSV files: {', '.join(missing)}")

    results = PROJECT / "results"
    dashboard = PROJECT / "dashboard"
    results.mkdir(exist_ok=True)
    dashboard.mkdir(exist_ok=True)

    with TemporaryDirectory(prefix="olist-build-", dir=PROJECT) as temp_dir:
        stage = Path(temp_dir)
        prepare_sources(source_dir, stage)
        run_sql(psql, connection_options, stage)
        write_results(stage)
        for name in EXPORTS:
            (stage / f"{name}.csv").replace(results / f"{name}.csv")
        (stage / "dashboard-data.json").replace(dashboard / "dashboard-data.json")

    print("PostgreSQL schema: olist_delivery")
    print(f"SQL exports: {results}")
    print("All SQL data checks passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", required=True, type=Path, help="Directory with the Olist CSV files")
    parser.add_argument("--dbname", required=True, help="Existing PostgreSQL database")
    parser.add_argument("--host", help="PostgreSQL host (default: libpq settings)")
    parser.add_argument("--port", help="PostgreSQL port (default: libpq settings)")
    parser.add_argument("--user", help="PostgreSQL role (default: libpq settings)")
    parser.add_argument("--psql", default="psql", help="Path to psql if it is outside PATH")
    args = parser.parse_args()

    psql = shutil.which(args.psql)
    if psql is None:
        parser.error("psql не найден. Укажите путь к нему через --psql.")
    connection_options = [f"--dbname={args.dbname}"]
    for option in ("host", "port", "user"):
        value = getattr(args, option)
        if value is not None:
            flag = "username" if option == "user" else option
            connection_options.append(f"--{flag}={value}")
    build(args.data_dir, str(Path(psql).resolve()), connection_options)


if __name__ == "__main__":
    main()
