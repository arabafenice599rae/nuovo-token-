#!/usr/bin/env bash
# The frontend hardcodes function selectors so it can stay dependency-free.
# This asserts each one against the compiled contract, so a signature change in
# FixedSaleV4 cannot silently leave the page calling into nothing.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="frontend/app.js"
status=0
checked=0

while IFS=$'\t' read -r selector signature; do
    expected="$(cast sig "$signature")"
    if [[ "$selector" != "$expected" ]]; then
        echo "MISMATCH  $signature: app.js has $selector, contract has $expected" >&2
        status=1
    fi
    checked=$((checked + 1))
done < <(grep -oE '"0x[0-9a-f]{8}",? // [A-Za-z0-9_]+\([a-z0-9,]*\)' "$APP" \
    | sed -E 's/"(0x[0-9a-f]{8})",? \/\/ (.+)/\1\t\2/')

if [[ "$checked" -eq 0 ]]; then
    echo "check-selectors: no selectors found in $APP — did the format change?" >&2
    exit 1
fi

echo "check-selectors: $checked selectors match the contract"
exit "$status"
