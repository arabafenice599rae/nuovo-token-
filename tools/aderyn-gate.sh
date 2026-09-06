#!/usr/bin/env bash
# Aderyn always exits 0, findings or not: this gate fails the pipeline when the
# JSON report contains findings of High severity.
set -euo pipefail

REPORT="${1:-reports/aderyn-report.json}"

if [[ ! -f "$REPORT" ]]; then
    echo "aderyn-gate: report not found: $REPORT" >&2
    exit 1
fi

python3 - "$REPORT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    report = json.load(fh)

highs = report.get("high_issues", {}).get("issues", [])
lows = report.get("low_issues", {}).get("issues", [])

for issue in highs:
    for instance in issue.get("instances", []):
        print(f"HIGH {instance.get('contract_path')}:{instance.get('line_no')} {issue.get('title')}")

print(f"aderyn-gate: {len(highs)} High findings, {len(lows)} Low findings")
sys.exit(1 if highs else 0)
PY
