#!/usr/bin/env bash
# Test-only lock holder. The parent owns the control directory and reaps us.
set -Eeuo pipefail
lock=$1 control=$2 mode=$3
printf '%s\n' "$$" > "$control/pid"
case "$mode" in
  flock) exec 9<>"$lock"; flock -n 9 ;;
  none) ;;
  *) exit 2 ;;
esac
trap 'exit 143' TERM INT
: > "$control/ready"
for _ in $(seq 1 100); do
  [ ! -e "$control/release" ] || exit 0
  sleep 0.1 9>&-
done
exit 124
