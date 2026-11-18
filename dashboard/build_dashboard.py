"""Embed SQL aggregates into the self-contained HTML dashboard."""
import json
from pathlib import Path

dashboard = Path(__file__).resolve().parent
data = json.loads((dashboard / "dashboard-data.json").read_text(encoding="utf-8-sig"))
required = {"summary", "severity", "severity_by_state", "monthly", "monthly_by_state", "segments"}
if required - data.keys() or any(not data[key] for key in required):
    raise SystemExit("Dashboard data is missing a required aggregate.")

template = (dashboard / "index.template.html").read_text(encoding="utf-8")
placeholder = "__OLIST_AGGREGATES__"
if template.count(placeholder) != 1:
    raise SystemExit("Expected one data placeholder in the dashboard template.")

embedded = json.dumps(data, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
html = template.replace(placeholder, embedded.replace("<", r"\u003c"))
(dashboard / "index.html").write_text(html, encoding="utf-8")
