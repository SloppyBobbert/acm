#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/acm-lock-ipc.XXXXXX")
HOLDER='' ACTUAL='' CONTROL=''
pass(){ printf 'ok - %s\n' "$1"; }
fail(){ printf 'not ok - %s\n' "$*" >&2; exit 1; }
alive(){ kill -0 "$1" 2>/dev/null && ! ps -o stat= -p "$1" 2>/dev/null | grep -Eq '^[[:space:]]*[Zz]'; }
wait_dead(){ local pid=$1 n=$2; for _ in $(seq 1 "$n"); do alive "$pid" || return 0; sleep 0.1; done; return 1; }
reap(){ local status; alive "$HOLDER" && return 1; if wait "$HOLDER"; then return 0; else status=$?; return "$status"; fi; }
cleanup(){ local original=$? status=0; if [ -n "$HOLDER" ] && alive "$HOLDER"; then : > "$CONTROL/release"; wait_dead "$ACTUAL" 30 || { kill -TERM "$ACTUAL" 2>/dev/null || true; wait_dead "$ACTUAL" 10 || { kill -KILL "$ACTUAL" 2>/dev/null || true; wait_dead "$ACTUAL" 10 || status=1; }; }; fi; if [ -n "$HOLDER" ] && ! alive "$HOLDER"; then reap || true; elif [ -n "$HOLDER" ]; then status=1; fi; [ "$status" = 0 ] || printf 'lock-holder cleanup failed\n' >&2; return "$original"; }
trap cleanup EXIT
start(){ local mode=$1; CONTROL="$FIXTURE/control-$mode-$RANDOM"; mkdir -m 0700 "$CONTROL"; bash "$ROOT/deploy/tests/support/lock-holder.sh" "$FIXTURE/lock" "$CONTROL" "$mode" & HOLDER=$!; for _ in $(seq 1 30); do [ -f "$CONTROL/ready" ] && break; alive "$HOLDER" || fail 'holder exited before ready'; sleep 0.1; done; [ -f "$CONTROL/ready" ] || fail 'holder readiness timed out'; ACTUAL=$(<"$CONTROL/pid"); [[ "$ACTUAL" =~ ^[1-9][0-9]*$ ]] && alive "$ACTUAL" || fail 'holder did not publish a live PID'; }
release(){ : > "$CONTROL/release"; wait_dead "$ACTUAL" 30 || fail 'holder did not release'; reap || fail 'normal holder release did not exit zero'; HOLDER=''; }
start none; release; pass 'normal release'
start none; : > "$CONTROL/release"; release; pass 'release before polling'
start none; wait_dead "$ACTUAL" 105 || fail 'holder did not expire'; if reap; then expired=0; else expired=$?; fi; [ "$expired" = 124 ] || fail "holder expiry status was $expired"; HOLDER=''; pass 'expiry returns 124'
start none; kill -TERM "$ACTUAL"; wait_dead "$ACTUAL" 10 || fail 'TERM did not stop holder'; if reap; then terminated=0; else terminated=$?; fi; [ "$terminated" -ne 0 ] || fail 'TERM returned zero'; HOLDER=''; pass 'TERM is nonzero'
start none; cleanup; HOLDER=''; start none; release; pass 'repeated immediate release'
printf '1..5 # fixtures retained at %s\n' "$FIXTURE"
