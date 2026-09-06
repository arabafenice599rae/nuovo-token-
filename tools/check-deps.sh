#!/usr/bin/env bash
# Verifica che le dipendenze in lib/ siano ai commit pinnati.
# I submodule di primo livello sono pinnati da .gitmodules + indice git;
# solmate e' un submodule di v4-core e vive in lib/v4-core/lib/solmate perche'
# gli import di v4-core lo cercano li'.
set -euo pipefail

cd "$(dirname "$0")/.."

SOLMATE_COMMIT="4b47a19038b798b4a33d9749d25e570443520647"

status=0

while read -r _ commit _ path; do
    if [[ ! -d "$path/.git" && ! -f "$path/.git" ]]; then
        echo "MANCANTE  $path (atteso $commit) - esegui 'make install'" >&2
        status=1
        continue
    fi
    actual="$(git -C "$path" rev-parse HEAD)"
    if [[ "$actual" != "$commit" ]]; then
        echo "DISALLINEATO $path: atteso $commit, trovato $actual" >&2
        status=1
    else
        echo "ok  $path  $commit"
    fi
done < <(git ls-files -s lib | grep '^160000')

if [[ ! -d lib/v4-core/lib/solmate/.git && ! -f lib/v4-core/lib/solmate/.git ]]; then
    echo "MANCANTE  lib/v4-core/lib/solmate (atteso $SOLMATE_COMMIT) - esegui 'make install'" >&2
    status=1
else
    actual="$(git -C lib/v4-core/lib/solmate rev-parse HEAD)"
    if [[ "$actual" != "$SOLMATE_COMMIT" ]]; then
        echo "DISALLINEATO lib/v4-core/lib/solmate: atteso $SOLMATE_COMMIT, trovato $actual" >&2
        status=1
    else
        echo "ok  lib/v4-core/lib/solmate  $SOLMATE_COMMIT"
    fi
fi

exit "$status"
