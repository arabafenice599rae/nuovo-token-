#!/usr/bin/env bash
# Assert the dependencies in lib/ sit at their pinned commits.
# Top-level submodules are pinned by .gitmodules plus the git index; solmate is
# a submodule of v4-core and lives in lib/v4-core/lib/solmate, because that is
# where v4-core's own imports look for it.
set -euo pipefail

cd "$(dirname "$0")/.."

SOLMATE_COMMIT="4b47a19038b798b4a33d9749d25e570443520647"

status=0

while read -r _ commit _ path; do
    if [[ ! -d "$path/.git" && ! -f "$path/.git" ]]; then
        echo "MISSING   $path (expected $commit) - run 'make install'" >&2
        status=1
        continue
    fi
    actual="$(git -C "$path" rev-parse HEAD)"
    if [[ "$actual" != "$commit" ]]; then
        echo "MISMATCH  $path: expected $commit, found $actual" >&2
        status=1
    else
        echo "ok  $path  $commit"
    fi
done < <(git ls-files -s lib | grep '^160000')

if [[ ! -d lib/v4-core/lib/solmate/.git && ! -f lib/v4-core/lib/solmate/.git ]]; then
    echo "MISSING   lib/v4-core/lib/solmate (expected $SOLMATE_COMMIT) - run 'make install'" >&2
    status=1
else
    actual="$(git -C lib/v4-core/lib/solmate rev-parse HEAD)"
    if [[ "$actual" != "$SOLMATE_COMMIT" ]]; then
        echo "MISMATCH  lib/v4-core/lib/solmate: expected $SOLMATE_COMMIT, found $actual" >&2
        status=1
    else
        echo "ok  lib/v4-core/lib/solmate  $SOLMATE_COMMIT"
    fi
fi

exit "$status"
