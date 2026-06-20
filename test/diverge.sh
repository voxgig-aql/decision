#!/usr/bin/env bash
# Interpreter-vs-bytecode divergence gate.
#
# AQL ships two execution engines:
#   * the default tree-walking INTERPRETER (`aql script.aql`), and
#   * the experimental BYTECODE compiler (`aql --force-compile script.aql`),
#     which compiles the program to a flat strict-stack form and runs it on
#     the kernel VM. `--force-compile` ABORTS with a refusal reason when a
#     program isn't compilable, rather than silently falling back to the
#     interpreter (that silent fallback is the plain `--compile` mode).
#
# A correct runtime must give the SAME answer on both engines. This script
# runs each bytecode-compilable suite under BOTH engines of the SAME aql build
# and asserts the output is byte-identical and both exit 0. Any difference — a
# divergent result, or one engine erroring where the other did not — fails the
# gate.
#
# The library's pinned aql (.github/workflows/test.yml AQL_REF, 958c379b)
# PREDATES the bytecode compiler, so this gate needs a newer aql. It resolves
# one without disturbing the project pin, in this order:
#   1. $BYTECODE_AQL, if set and it accepts --force-compile;
#   2. the on-PATH `aql`, if it already accepts --force-compile;
#   3. a build from $BYTECODE_AQL_REF (default below) into ~/.local/bin,
#      cached for re-use. Requires `go` + network on first run.
#
# Run from anywhere:
#   bash test/diverge.sh
#   BYTECODE_AQL=/path/to/aql bash test/diverge.sh
set -uo pipefail

# Resolve to the repo root so the suites' relative `import "./decision.aql"`
# resolves regardless of the caller's working directory.
cd "$(dirname "$0")/.."

# A recent aql-lang/aql main commit that ships the bytecode compiler and its
# `--compile` / `--force-compile` flags. Separate from the library's pinned
# interpreter ref ON PURPOSE — bump it independently as the compiler matures.
BYTECODE_AQL_REF="${BYTECODE_AQL_REF:-c44d994f33c5cc39b2a1cc4d2f170b3b0aa07431}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

# Does $1 understand --force-compile? (An aql built from a pre-bytecode commit
# rejects the flag with "flag provided but not defined".)
supports_force_compile() {
  [ -n "$1" ] && command -v "$1" >/dev/null 2>&1 && "$1" --force-compile -e '1 2 add' >/dev/null 2>&1
}

# Build a bytecode-capable aql from BYTECODE_AQL_REF, mirroring the
# session-start hook. Echoes the binary path on success.
build_bytecode_aql() {
  local bin="$HOME/.local/bin/aql-bytecode-${BYTECODE_AQL_REF:0:12}"
  if supports_force_compile "$bin"; then echo "$bin"; return 0; fi
  command -v go >/dev/null 2>&1 || { red "no \`go\` toolchain; cannot build a bytecode-capable aql (see docs/how-to.md)"; return 1; }
  red "building bytecode-capable aql @ ${BYTECODE_AQL_REF:0:12} (one-time; cached)…" >&2
  local src; src="$(mktemp -d)"
  if git clone --quiet https://github.com/aql-lang/aql "$src" \
     && git -C "$src" checkout --quiet "$BYTECODE_AQL_REF" \
     && ( cd "$src/cmd/go" && GOFLAGS=-mod=mod go build \
            -ldflags "-X github.com/aql-lang/aql/cmd/go.Version=${BYTECODE_AQL_REF}" \
            -o "$bin" ./aql ); then
    rm -rf "$src"; echo "$bin"; return 0
  fi
  rm -rf "$src"; red "build failed (see docs/how-to.md to build manually)"; return 1
}

# Pick the aql to drive both engines with.
AQL=""
if supports_force_compile "${BYTECODE_AQL:-}"; then
  AQL="$BYTECODE_AQL"
elif supports_force_compile aql; then
  AQL="aql"
else
  AQL="$(build_bytecode_aql)" || exit 2
  supports_force_compile "$AQL" || { red "resolved aql still rejects --force-compile: $AQL"; exit 2; }
fi
green "using bytecode-capable aql: $("$AQL" -version 2>/dev/null || echo "$AQL")"

# Suites the bytecode compiler fully accepts today. The spec/prop suites use
# `each` / code-body words the experimental compiler still refuses (it aborts
# under --force-compile rather than miscomputing); they are covered by the
# interpreter runs in CI. The imperative unit suite exercises every public
# evaluator (apply-op, eval-cond, eval-pred, every eval-table hit policy,
# eval-tree, decide), so the bytecode VM is genuinely driven through the whole
# Decision surface here.
COMPILABLE=(
  test/decision_smoke_test.aql
  test/decision_unit_test.aql
)

fail=0
for suite in "${COMPILABLE[@]}"; do
  int_out="$("$AQL"                "$suite" 2>&1)"; int_rc=$?
  byt_out="$("$AQL" --force-compile "$suite" 2>&1)"; byt_rc=$?

  if [ "$int_rc" -ne 0 ]; then
    red "DIVERGE  $suite: interpreter exited $int_rc"
    printf '%s\n' "$int_out" | sed 's/^/    | /'
    fail=1
    continue
  fi
  if [ "$byt_rc" -ne 0 ]; then
    red "DIVERGE  $suite: bytecode (--force-compile) exited $byt_rc"
    printf '%s\n' "$byt_out" | sed 's/^/    | /'
    fail=1
    continue
  fi
  if [ "$int_out" != "$byt_out" ]; then
    red "DIVERGE  $suite: interpreter and bytecode output differ"
    diff <(printf '%s\n' "$int_out") <(printf '%s\n' "$byt_out") | sed 's/^/    /'
    fail=1
    continue
  fi
  green "ok       $suite: interpreter == bytecode"
done

echo "---"
if [ "$fail" -ne 0 ]; then
  red "interpreter/bytecode DIVERGENCE detected"
  exit 1
fi
green "no divergence: interpreter and bytecode agree on all ${#COMPILABLE[@]} compilable suite(s)"
