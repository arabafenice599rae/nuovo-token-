#!/usr/bin/env bash
# Aderyn esce sempre con codice 0: questo gate fa fallire la pipeline
# quando il report JSON contiene finding di severita' High.
set -euo pipefail

REPORT="${1:-reports/aderyn-report.json}"

if [[ ! -f "$REPORT" ]]; then
    echo "aderyn-gate: report non trovato: $REPORT" >&2
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

print(f"aderyn-gate: {len(highs)} finding High, {len(lows)} finding Low")
sys.exit(1 if highs else 0)
PY
