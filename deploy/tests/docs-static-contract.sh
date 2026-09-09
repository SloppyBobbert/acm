#!/usr/bin/env bash
# Guards operator-facing deployment contracts without invoking host tooling.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
PASS=0
pass(){ PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
fail(){ printf 'not ok - %s\n' "$*" >&2; exit 1; }

docs=("$ROOT/README.md" "$ROOT/deploy/README.md" "$ROOT/docs/configuration.md" "$ROOT/docs/operations.md" "$ROOT/docs/testing.md")
for doc in "${docs[@]}"; do
  while IFS= read -r line; do
    [[ "$line" == *'sudo /usr/local/libexec/acm/smoke.sh'* ]] || continue
    [[ "$line" == *'--repository-dir "$(pwd -P)"'* ]] || fail "installed smoke example lacks repository argument: $doc"
  done < "$doc"
done
pass 'installed smoke examples include the repository argument'

grep -Fq '/run/lock/acm/acm-operation.lock' "$ROOT/deploy/README.md" || fail 'deployment docs omit the current operation lock path'
if grep -Eq '/run/lock/(acm\.lock|acm-deploy\.lock|acm-db\.lock)' "${docs[@]}"; then
  fail 'deployment docs mention a retired operation lock path'
fi
pass 'deployment docs name only the current operation lock path'

printf '1..%s\n' "$PASS"
