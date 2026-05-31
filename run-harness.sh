#!/usr/bin/env bash
#
# Repro harness for the `alchemy dev` multi-worker silent-startup bug.
#
# For each suite it does a clean install (removes node_modules + .alchemy,
# toggles the patch, `bun install`), then runs `alchemy dev` N times, counting
# how many of the 3 workers print "Started in". Between runs it kills leftover
# workerd/alchemy processes and wipes .alchemy so every run is independent.
#
# Each run waits for the stack to report "Done:" (the deploy/bundle finished —
# this absorbs a slow cold-start bundle), then waits GRACE seconds for the
# workers to print "Started in", then decides. It returns early the moment all
# 3 have started. A high internal CEILING is only a hang safety-net, so there is
# no too-small timeout to produce false negatives on a cold first run.
#
# Usage:
#   ./run-harness.sh [N] [GRACE] [mode]
#
# Modes:
#   (default)     unpatched runtime  -> demonstrates the bug
#   --patch       patched runtime    -> demonstrates the fix
#   --both        run the entire suite: unpatched, then patched (comparison)
#
# Positional: N = iterations per suite (default 10), GRACE = seconds to wait
# after "Done:" for stragglers to start (default 4).
#
#   ./run-harness.sh                # 10 unpatched runs
#   ./run-harness.sh --patch        # 10 patched runs
#   ./run-harness.sh 12 4 --both    # 12 unpatched + 12 patched, 4s grace
#
# Ctrl-C is handled: it tears down workerd/alchemy and restores package.json.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PATCH_PKG="@distilled.cloud/cloudflare-runtime@0.6.3"
PATCH_PATH="patches/@distilled.cloud%2Fcloudflare-runtime@0.6.3.patch"
WORKERD_GLOB="node_modules/.bun/@distilled.cloud+cloudflare-runtime@*/node_modules/@distilled.cloud/cloudflare-runtime/dist/workerd/Workerd.mjs"

N=10
GRACE=4         # seconds to wait after "Done:" for stragglers to print "Started"
CEILING=60      # hard hang safety-net: max seconds for "Done:" to ever appear
MODE="unpatched"

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }

positional=()
for a in "$@"; do
  case "$a" in
    --patch)     MODE="patched" ;;
    --both)      MODE="both" ;;
    --unpatched) MODE="unpatched" ;;
    -h|--help)   usage; exit 0 ;;
    --*)         echo "unknown flag: $a" >&2; usage; exit 1 ;;
    *)           positional+=("$a") ;;
  esac
done
[ "${#positional[@]}" -ge 1 ] && N="${positional[0]}"
[ "${#positional[@]}" -ge 2 ] && GRACE="${positional[1]}"

# Mirror the parent project's `clean` script (fd-based). `-X` batches results
# into a single `rm` AFTER traversal completes, avoiding the "fts_read failed"
# race that `-x` causes by removing dirs while fd is still walking them.
clean_all()     { fd -t d '^(node_modules|\.alchemy)$' -HI -X rm -rf 2>/dev/null; }
clean_alchemy() { fd -t d '^\.alchemy$'                -HI -X rm -rf 2>/dev/null; }

kill_procs() {
  pkill -f 'alchemy/bin/exec' 2>/dev/null
  pkill -f 'Cloudflare/Local'  2>/dev/null
  pkill -f 'workerd'           2>/dev/null
  sleep 1
}

# Preserve the committed package.json; restore on any exit / interrupt.
cp package.json /tmp/repro-pkg.bak
restore_pkg()      { cp /tmp/repro-pkg.bak package.json 2>/dev/null; }
interrupted() {
  echo; echo ">>> interrupted — tearing down workerd/alchemy and restoring package.json"
  [ -n "${RUN_PID:-}" ] && kill "$RUN_PID" 2>/dev/null
  kill_procs; restore_pkg
  exit 130
}
trap interrupted INT TERM
trap restore_pkg EXIT

set_patch() { # on|off
  if [ "$1" = "on" ]; then
    jq --arg k "$PATCH_PKG" --arg v "$PATCH_PATH" \
      '.patchedDependencies = {($k): $v}' package.json > package.json.tmp
  else
    jq 'del(.patchedDependencies)' package.json > package.json.tmp
  fi
  mv package.json.tmp package.json
}

verify_runtime() {
  local f; f=$(ls $WORKERD_GLOB 2>/dev/null | head -1)
  if [ -n "$f" ] && grep -q "allocatePort" "$f" 2>/dev/null; then
    echo "PATCHED (port pre-alloc + TCP readiness poll, no --control-fd)"
  else
    echo "UNPATCHED (--control-fd=3, fd-3 port report)"
  fi
}

install_suite() { # patched|unpatched
  echo
  echo ">>> Preparing '$1' suite: clean node_modules + .alchemy, toggle patch, bun install"
  clean_all
  [ "$1" = "patched" ] && set_patch on || set_patch off
  bun install >"/tmp/repro-install-$1.log" 2>&1 \
    || { echo "    !! bun install failed — see /tmp/repro-install-$1.log"; tail -5 "/tmp/repro-install-$1.log"; }
  echo "    runtime: $(verify_runtime)"
}

# Run `alchemy dev` once in the background, poll its log, and decide.
# Waits for "Done:" (deploy/bundle complete — absorbs cold-start bundles), then
# GRACE seconds for stragglers, returning early once all 3 start. Echoes the
# started count, or "TIMEOUT" if "Done:" never appeared within CEILING (an
# invalid sample, NOT a 0/3 — distinguishes a hang from a real incomplete).
run_once() { # logfile
  local log="$1" started_count=0 done_at=0 start=$SECONDS
  ( cd packages/infra && exec bun run dev ) >"$log" 2>&1 &
  RUN_PID=$!
  while kill -0 "$RUN_PID" 2>/dev/null; do
    started_count=$(grep -c "Started in" "$log" 2>/dev/null); started_count=${started_count:-0}
    [ "$started_count" -ge 3 ] && break                       # full success: stop now
    if [ "$done_at" -eq 0 ] && grep -q "Done:" "$log" 2>/dev/null; then done_at=$SECONDS; fi
    if [ "$done_at" -ne 0 ] && [ $((SECONDS - done_at)) -ge "$GRACE" ]; then break; fi
    [ $((SECONDS - start)) -ge "$CEILING" ] && break          # hang safety-net only
    sleep 0.5
  done
  kill "$RUN_PID" 2>/dev/null
  RUN_PID=""
  local final; final=$(grep -c "Started in" "$log" 2>/dev/null); final=${final:-0}
  # "Done:" never appeared -> deploy didn't finish in time; not a fair sample.
  if [ "$done_at" -eq 0 ] && [ "$final" -lt 3 ]; then echo "TIMEOUT"; else echo "$final"; fi
}

SUMMARY=()
run_suite() { # label
  local label="$1" i n started log total_full=0 valid=0 timeouts=0
  declare -A hist=()
  echo
  echo "############ SUITE: $label  (N=$N, grace=${GRACE}s) ############"
  for i in $(seq 1 "$N"); do
    clean_alchemy
    log="/tmp/repro-${label}-$i.log"
    n=$(run_once "$log")
    started=$(grep -oE "Worker[ABC]\] Started in" "$log" | grep -oE "Worker[ABC]" | sort -u | tr '\n' ',' | sed 's/,$//')
    if [ "$n" = "TIMEOUT" ]; then
      timeouts=$((timeouts + 1))
      printf "  [%s] RUN %2d: TIMEOUT (deploy never finished — sample discarded)\n" "$label" "$i"
    else
      valid=$((valid + 1))
      hist[$n]=$(( ${hist[$n]:-0} + 1 ))
      [ "$n" -eq 3 ] && total_full=$((total_full + 1))
      printf "  [%s] RUN %2d: started=%d/3  [%s]%s\n" \
        "$label" "$i" "$n" "$started" "$([ "$n" -lt 3 ] && echo "   <<< INCOMPLETE")"
    fi
    kill_procs
  done
  echo "  --- $label distribution (valid samples) ---"
  for k in $(echo "${!hist[@]}" | tr ' ' '\n' | sort); do
    echo "    $k/3 -> ${hist[$k]} run(s)"
  done
  [ "$timeouts" -gt 0 ] && echo "    (timeouts/discarded: $timeouts)"
  echo "  >>> $label: $total_full/$valid valid runs started ALL 3 workers"
  SUMMARY+=("$label: $total_full/$valid valid runs started all 3 ($timeouts timed out)")
}

case "$MODE" in
  unpatched) install_suite unpatched; run_suite unpatched ;;
  patched)   install_suite patched;   run_suite patched ;;
  both)      install_suite unpatched; run_suite unpatched
             install_suite patched;   run_suite patched ;;
esac

echo
echo "================= SUMMARY ================="
for s in "${SUMMARY[@]}"; do echo "  $s"; done

if [ "$MODE" = "unpatched" ]; then
  echo
  echo "NOTE: node_modules left UNPATCHED. Committed default is patched —"
  echo "      run 'bun install' to resync if you want the fix locally."
fi
