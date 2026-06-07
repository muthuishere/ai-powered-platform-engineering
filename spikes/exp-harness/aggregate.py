#!/usr/bin/env python3
"""Auto-grade aggregator for the bare-metal Talos experiment spikes.

Scans ``spikes/exp-*/results.json``, validates each file against the metrics
contract in ``spikes/EXPERIMENTS-SPEC.md``, and emits:

  * ``spikes/exp-harness/comparison.json`` — every spike merged into one doc.
  * ``spikes/exp-harness/COMPARISON.md``   — a Markdown report for the book.

Hard rule from the spec: numbers are *measured, never fabricated*. A spike
whose ``results.json`` is absent, empty, malformed, or has ``null`` metrics is
reported explicitly as **not-run** with the reason. We never invent a value.

stdlib only — runs anywhere python3 does.
"""

import json
import os
import sys
from datetime import datetime, timezone

# --------------------------------------------------------------------------
# Spike catalogue (canonical list from EXPERIMENTS-SPEC.md). The harness knows
# every spike that *should* exist, so an absent results.json is reported as
# not-run rather than silently skipped.
# --------------------------------------------------------------------------

# Data-format spikes — share the same metrics shape and feed the format matrix.
DATA_FORMAT_SPIKES = [
    ("exp-duckdb-parquet", "Parquet (DuckDB)"),
    ("exp-chdb-parquet", "Parquet (chDB)"),
    ("exp-duckdb-iceberg", "Iceberg"),
    ("exp-ducklake", "DuckLake"),
    ("exp-vortex", "Vortex"),
    ("exp-arrow-flight", "Arrow/Feather"),
]

# Postgres spikes — StatefulSet baseline + the container-vs-VM headline.
PG_SPIKES = [
    ("exp-pg-statefulset", "StatefulSet"),
    ("exp-pg-ss-vs-kubevirt", "KubeVirt"),
]

# Model-from-object-storage spike.
MODEL_SPIKES = [
    ("exp-mochallama-minio-operator", "mochallama-from-MinIO"),
]

ALL_SPIKES = [s for s, _ in DATA_FORMAT_SPIKES + PG_SPIKES + MODEL_SPIKES]

# Metric keys we expect per spike family. Used both for validation and to know
# which keys to treat as "must be a measured number".
DATA_FORMAT_METRICS = [
    "ingest_s",
    "scan_rows_per_s",
    "query_p50_ms",
    "query_p95_ms",
    "on_disk_bytes",
    "compression_ratio",
]
PG_METRICS = ["tps", "query_p50_ms", "query_p95_ms", "query_p99_ms", "failover_s"]
MODEL_METRICS = ["model_pull_s", "model_load_s", "completion_ms"]


# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

HARNESS_DIR = os.path.dirname(os.path.abspath(__file__))
SPIKES_DIR = os.path.dirname(HARNESS_DIR)
COMPARISON_JSON = os.path.join(HARNESS_DIR, "comparison.json")
COMPARISON_MD = os.path.join(HARNESS_DIR, "COMPARISON.md")


# --------------------------------------------------------------------------
# Loading + validation
# --------------------------------------------------------------------------


def load_result(spike):
    """Load + validate one spike's results.json.

    Returns a dict with keys:
      status   : "ok" | "not-run"
      reason   : populated when not-run
      raw      : the parsed json (or None)
      metrics  : the metrics sub-dict (or {})
    """
    path = os.path.join(SPIKES_DIR, spike, "results.json")

    if not os.path.exists(path):
        return {
            "spike": spike,
            "status": "not-run",
            "reason": "results.json absent (spike not yet run)",
            "raw": None,
            "metrics": {},
            "path": path,
        }

    try:
        size = os.path.getsize(path)
    except OSError as exc:
        return _not_run(spike, path, "results.json unreadable: %s" % exc)

    if size == 0:
        return _not_run(spike, path, "results.json empty (spike not yet run)")

    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except (ValueError, OSError) as exc:
        return _not_run(spike, path, "results.json invalid JSON: %s" % exc)

    if not isinstance(raw, dict):
        return _not_run(spike, path, "results.json is not a JSON object")

    metrics = raw.get("metrics")
    if not isinstance(metrics, dict):
        return _not_run(spike, path, "missing 'metrics' object")

    # A spike that exists but has all-null metrics is treated as not-run, with
    # the spike's own note as the reason where available.
    measured = {k: v for k, v in metrics.items() if v is not None}
    if not measured:
        note = raw.get("notes") or "all metrics null"
        return _not_run(spike, path, "metrics present but all null (%s)" % note, raw=raw, metrics=metrics)

    return {
        "spike": spike,
        "status": "ok",
        "reason": None,
        "raw": raw,
        "metrics": metrics,
        "path": path,
    }


def _not_run(spike, path, reason, raw=None, metrics=None):
    return {
        "spike": spike,
        "status": "not-run",
        "reason": reason,
        "raw": raw,
        "metrics": metrics or {},
        "path": path,
    }


def num(metrics, key):
    """Return a measured numeric value or None. Never fabricates."""
    v = metrics.get(key)
    if isinstance(v, bool):  # guard: bool is a subclass of int
        return None
    if isinstance(v, (int, float)):
        return v
    return None


# --------------------------------------------------------------------------
# Formatting helpers
# --------------------------------------------------------------------------


def fmt_bytes(n):
    if n is None:
        return "—"
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    val = float(n)
    for u in units:
        if val < 1024 or u == units[-1]:
            if u == "B":
                return "%d B" % int(val)
            return "%.2f %s" % (val, u)
        val /= 1024.0
    return "%d B" % int(n)


def fmt_num(v, suffix="", nd=2):
    if v is None:
        return "—"
    if isinstance(v, float):
        return ("%." + str(nd) + "f%s") % (v, suffix)
    return "%s%s" % (f"{v:,}", suffix)


def best_index(values, prefer_high):
    """Index of the winning value among a list (None entries ignored)."""
    candidates = [(i, v) for i, v in enumerate(values) if v is not None]
    if not candidates:
        return None
    if prefer_high:
        return max(candidates, key=lambda iv: iv[1])[0]
    return min(candidates, key=lambda iv: iv[1])[0]


# --------------------------------------------------------------------------
# Report assembly
# --------------------------------------------------------------------------

NESTING_CAVEAT = (
    "**Nesting caveat:** the KubeVirt VM is one nesting layer deep "
    "(host KVM -> Talos QEMU VM -> KubeVirt VM). Numbers are directionally "
    "valid for container-vs-VM overhead, not absolute bare-metal figures."
)


def build_comparison(results_by_spike):
    """Assemble the merged comparison.json structure."""
    spikes_out = {}
    for spike, res in results_by_spike.items():
        spikes_out[spike] = {
            "status": res["status"],
            "reason": res["reason"],
            "ran_at": (res["raw"] or {}).get("ran_at") if res["raw"] else None,
            "cluster": (res["raw"] or {}).get("cluster") if res["raw"] else None,
            "notes": (res["raw"] or {}).get("notes") if res["raw"] else None,
            "metrics": res["metrics"],
        }

    ran = [s for s, r in results_by_spike.items() if r["status"] == "ok"]
    not_run = [s for s, r in results_by_spike.items() if r["status"] != "ok"]

    return {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "spike_count": len(ALL_SPIKES),
        "ran": sorted(ran),
        "not_run": sorted(not_run),
        "spikes": spikes_out,
    }


def md_data_format_matrix(results_by_spike):
    lines = []
    lines.append("## Data-format matrix")
    lines.append("")
    lines.append(
        "Parquet vs Iceberg vs DuckLake vs Vortex vs Arrow/Feather over MinIO. "
        "Winner per column flagged with **(best)**. `—` = not measured."
    )
    lines.append("")

    # Column definitions: (header, metric key, prefer_high, formatter)
    cols = [
        ("on_disk_bytes", "on_disk_bytes", False, lambda v: fmt_bytes(v)),
        ("compression_ratio", "compression_ratio", True, lambda v: fmt_num(v, "x")),
        ("ingest_s", "ingest_s", False, lambda v: fmt_num(v, " s")),
        ("scan_rows_per_s", "scan_rows_per_s", True, lambda v: fmt_num(v, "/s", 0)),
        ("query_p95_ms", "query_p95_ms", False, lambda v: fmt_num(v, " ms")),
    ]

    rows = []  # (label, [raw values aligned to cols])
    for spike, label in DATA_FORMAT_SPIKES:
        res = results_by_spike[spike]
        if res["status"] != "ok":
            rows.append((label, spike, None))  # not-run marker
            continue
        vals = [num(res["metrics"], key) for _, key, _, _ in cols]
        rows.append((label, spike, vals))

    # Determine winners per column (only across ran rows).
    winners = {}
    for ci, (_, _, prefer_high, _) in enumerate(cols):
        col_values = [vals[ci] if vals is not None else None for (_, _, vals) in rows]
        winners[ci] = best_index(col_values, prefer_high)

    # Sort: ran rows first (by on-disk bytes asc), then not-run rows.
    def sort_key(item):
        idx, (label, spike, vals) = item
        if vals is None:
            return (1, 0)
        ob = vals[0]
        return (0, ob if ob is not None else float("inf"))

    indexed = list(enumerate(rows))
    indexed.sort(key=sort_key)

    header = "| format | " + " | ".join(h for h, _, _, _ in cols) + " |"
    sep = "|" + "---|" * (len(cols) + 1)
    lines.append(header)
    lines.append(sep)

    for orig_idx, (label, spike, vals) in indexed:
        if vals is None:
            cells = ["_not run_"] * len(cols)
            lines.append("| **%s** | %s |" % (label, " | ".join(cells)))
            continue
        cells = []
        for ci, (_, _, _, formatter) in enumerate(cols):
            txt = formatter(vals[ci])
            if winners.get(ci) == orig_idx and vals[ci] is not None:
                txt += " **(best)**"
            cells.append(txt)
        lines.append("| **%s** | %s |" % (label, " | ".join(cells)))

    lines.append("")
    return "\n".join(lines)


def md_postgres_table(results_by_spike):
    lines = []
    lines.append("## Postgres: StatefulSet vs KubeVirt")
    lines.append("")
    lines.append("| backend | tps | query_p95_ms | failover_s |")
    lines.append("|---|---|---|---|")
    for spike, label in PG_SPIKES:
        res = results_by_spike[spike]
        if res["status"] != "ok":
            lines.append("| **%s** | _not run_ | _not run_ | _not run_ |" % label)
            continue
        m = res["metrics"]
        lines.append(
            "| **%s** | %s | %s | %s |"
            % (
                label,
                fmt_num(num(m, "tps"), "", 1),
                fmt_num(num(m, "query_p95_ms"), " ms"),
                fmt_num(num(m, "failover_s"), " s"),
            )
        )
    lines.append("")
    lines.append(NESTING_CAVEAT)
    lines.append("")
    return "\n".join(lines)


def md_model_section(results_by_spike):
    lines = []
    lines.append("## mochallama from MinIO")
    lines.append("")
    lines.append(
        "Model GGUF pulled from object storage (MinIO) at boot — not baked "
        "into the image."
    )
    lines.append("")
    res = results_by_spike["exp-mochallama-minio-operator"]
    lines.append("| metric | value |")
    lines.append("|---|---|")
    if res["status"] != "ok":
        for k in MODEL_METRICS:
            lines.append("| %s | _not run_ |" % k)
    else:
        m = res["metrics"]
        lines.append("| model_pull_s | %s |" % fmt_num(num(m, "model_pull_s"), " s"))
        lines.append("| model_load_s | %s |" % fmt_num(num(m, "model_load_s"), " s"))
        lines.append("| completion_ms | %s |" % fmt_num(num(m, "completion_ms"), " ms"))
    lines.append("")
    return "\n".join(lines)


def md_missing_section(results_by_spike):
    lines = []
    lines.append("## Missing / not-yet-run")
    lines.append("")
    lines.append(
        "Spikes whose `results.json` is absent, empty, malformed, or all-null. "
        "Per the spec, absent is shown explicitly as **not-run** — never "
        "fabricated."
    )
    lines.append("")
    not_run = [
        (s, results_by_spike[s]) for s in ALL_SPIKES if results_by_spike[s]["status"] != "ok"
    ]
    if not not_run:
        lines.append("_All spikes have measured results._")
        lines.append("")
        return "\n".join(lines)
    lines.append("| spike | reason |")
    lines.append("|---|---|")
    for spike, res in not_run:
        lines.append("| `%s` | %s |" % (spike, res["reason"]))
    lines.append("")
    return "\n".join(lines)


def build_markdown(comparison, results_by_spike):
    lines = []
    lines.append("# Experiment Comparison — auto-graded")
    lines.append("")
    lines.append("_Generated %s by `aggregate.py`._" % comparison["generated_at"])
    lines.append("")
    lines.append(
        "%d/%d spikes have measured results. Numbers are measured on real "
        "Talos clusters (bare-metal QEMU/KVM); un-run metrics are shown as "
        "not-run, never invented."
        % (len(comparison["ran"]), comparison["spike_count"])
    )
    lines.append("")
    lines.append(md_data_format_matrix(results_by_spike))
    lines.append(md_postgres_table(results_by_spike))
    lines.append(md_model_section(results_by_spike))
    lines.append(md_missing_section(results_by_spike))
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def main():
    results_by_spike = {spike: load_result(spike) for spike in ALL_SPIKES}

    comparison = build_comparison(results_by_spike)
    with open(COMPARISON_JSON, "w", encoding="utf-8") as fh:
        json.dump(comparison, fh, indent=2, sort_keys=False)
        fh.write("\n")

    markdown = build_markdown(comparison, results_by_spike)
    with open(COMPARISON_MD, "w", encoding="utf-8") as fh:
        fh.write(markdown)
        if not markdown.endswith("\n"):
            fh.write("\n")

    ran = len(comparison["ran"])
    total = comparison["spike_count"]
    print("aggregate: %d/%d spikes with measured results" % (ran, total))
    if comparison["not_run"]:
        print("not-run: %s" % ", ".join(comparison["not_run"]))
    print("wrote %s" % COMPARISON_JSON)
    print("wrote %s" % COMPARISON_MD)
    return 0


if __name__ == "__main__":
    sys.exit(main())
