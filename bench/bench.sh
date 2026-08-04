#!/usr/bin/env bash
# Performance baseline harness for the Decision library.
#
# Runs bench/decision_bench.aql — a hot loop that builds a priority-policy
# decision table, a multi-level decision tree, and a compound predicate ONCE,
# then evaluates them across many synthetic inputs — under two execution modes:
#
#   * INTERPRETER  (`boru -no-compile`)      — the tree-walking engine
#   * BYTECODE     (`boru --force-compile`)  — the kernel VM (aborts, never
#                                             silently falls back, if any part
#                                             of the program refuses to lower)
#
# Both modes must print the SAME checksum (the differential invariant); the
# harness fails loudly if they diverge. It reports the best-of-N wall time for
# each mode and the resulting speedup, plus the fixed (n=1) overhead so the
# per-iteration execution cost can be separated from parse/check/compile.
#
# Resolving the boru build mirrors test/diverge.sh: pass a binary explicitly, or
# let it fall through to an on-PATH `boru`.
#
#   BENCH_AQL=/path/to/boru bash bench/bench.sh
#   ITERS=3000 RUNS=5      bash bench/bench.sh
set -uo pipefail
cd "$(dirname "$0")/.."   # repo root, so `import "./decision.aql"` resolves

AQL="${BENCH_AQL:-${BYTECODE_AQL:-boru}}"
ITERS="${ITERS:-3000}"
RUNS="${RUNS:-3}"
SRC="bench/decision_bench.aql"

command -v "$AQL" >/dev/null 2>&1 || { echo "no boru binary ($AQL); set BENCH_AQL"; exit 2; }

# Materialise the benchmark at the requested iteration count.
work="$(mktemp)"; trap 'rm -f "$work" "$over"' EXIT
sed "s/^for [0-9]* \[/for ${ITERS} [/" "$SRC" > "$work"
over="$(mktemp)"
sed "s/^for [0-9]* \[/for 1 [/" "$SRC" > "$over"

secs() { python3 -c 'import sys,time,subprocess;a=sys.argv[1:];t=time.perf_counter();subprocess.run(a,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);print(f"{time.perf_counter()-t:.4f}")' "$@"; }
best() { # best-of-$RUNS wall seconds for: <mode> <file>
  local b=1e9 i d
  for ((i=0;i<RUNS;i++)); do d="$(secs "$AQL" "$1" "$2")"; awk "BEGIN{exit !($d<$b)}" && b="$d"; done
  echo "$b"
}

# Differential: both modes must agree.
ci="$("$AQL" -no-compile "$work" 2>&1)"
cc="$("$AQL" --force-compile "$work" 2>&1)"
if [ "$ci" != "$cc" ]; then
  echo "DIVERGENCE: interpreter=[$ci] compiled=[$cc]"; exit 1
fi
echo "boru:     $("$AQL" -version 2>/dev/null || echo "$AQL")"
echo "workload: $SRC   iters=$ITERS   runs=$RUNS   checksum=$ci"
echo

oi="$(best -no-compile "$over")";      oc="$(best --force-compile "$over")"
ti="$(best -no-compile "$work")";      tc="$(best --force-compile "$work")"

awk -v oi="$oi" -v oc="$oc" -v ti="$ti" -v tc="$tc" -v n="$ITERS" 'BEGIN{
  printf "%-24s %-12s %-12s %s\n", "", "interpreter", "compiled", "ratio";
  printf "%-24s %-12.4f %-12.4f %.1fx\n", "total wall (s)", ti, tc, ti/tc;
  printf "%-24s %-12.4f %-12.4f\n",       "fixed overhead (s)", oi, oc;
  pi=(ti-oi)/n*1e6; pc=(tc-oc)/n*1e6;
  printf "%-24s %-12.1f %-12.1f %.1fx\n", "per-iter exec (us)", pi, pc, pi/pc;
}'
