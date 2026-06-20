#!/usr/bin/env bash
# Multi-mode test gate: run the suites under each of AQL's execution modes and
# require each to pass without errors.
#
# AQL can run a program three ways:
#   * INTERPRETER  — `aql script.aql`: the default tree-walking engine.
#   * CHECK        — `aql check script.aql`: the static type-checker (no
#                    execution); exits non-zero if it reports any error.
#   * BYTECODE     — `aql --force-compile script.aql`: compiles the program to
#                    a flat strict-stack form and runs it on the kernel VM.
#                    `--force-compile` ABORTS with a refusal reason when a
#                    program isn't compilable, rather than silently falling
#                    back to the interpreter (that fallback is plain
#                    `--compile`).
#
# Every suite must pass under the interpreter and the checker. The
# bytecode-compilable suites must ALSO pass under --force-compile AND produce
# output byte-identical to the interpreter — so the two engines never diverge.
# The spec/prop suites use `each` and other code-body words the experimental
# compiler still refuses; they run under the interpreter and the checker only,
# and are reported as such (not silently skipped) until the compiler accepts
# them — at which point, move them into COMPILABLE below.
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
dim()   { printf '\033[2m%s\033[0m\n'  "$*"; }

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

# Pick the aql to drive every mode with.
AQL=""
if supports_force_compile "${BYTECODE_AQL:-}"; then
  AQL="$BYTECODE_AQL"
elif supports_force_compile aql; then
  AQL="aql"
else
  AQL="$(build_bytecode_aql)" || exit 2
  supports_force_compile "$AQL" || { red "resolved aql still rejects --force-compile: $AQL"; exit 2; }
fi
green "aql: $("$AQL" -version 2>/dev/null || echo "$AQL")"
echo

# Every suite (must pass interpreter + check).
SUITES=(
  test/decision_unit_test.aql
  test/decision_unit_spec.aql
  test/decision_prop_test.aql
  test/decision_prop_spec.aql
  test/decision_smoke_test.aql
)

# The subset the bytecode compiler fully accepts today (must also pass
# --force-compile AND match the interpreter's output exactly). The imperative
# unit suite exercises every public evaluator — apply-op, eval-cond, eval-pred,
# every eval-table hit policy, eval-tree, decide — so the VM is genuinely
# driven across the whole Decision surface.
COMPILABLE=" test/decision_smoke_test.aql test/decision_unit_test.aql "

is_compilable() { case "$COMPILABLE" in *" $1 "*) return 0;; *) return 1;; esac; }

fail=0
for suite in "${SUITES[@]}"; do
  name="${suite#test/}"
  notes=()

  # Mode 1: interpreter. Capture stdout for the bytecode comparison.
  int_out="$("$AQL" "$suite" 2>&1)"; int_rc=$?
  if [ "$int_rc" -eq 0 ]; then notes+=("interp ok"); else
    notes+=("interp FAIL(rc=$int_rc)"); fail=1
  fi

  # Mode 2: check (static type-check; non-zero exit means it reported errors).
  chk_out="$("$AQL" check "$suite" 2>&1)"; chk_rc=$?
  if [ "$chk_rc" -eq 0 ]; then notes+=("check ok"); else
    notes+=("check FAIL(rc=$chk_rc)"); fail=1
  fi

  # Mode 3: bytecode (only where the compiler accepts the program).
  if is_compilable "$suite"; then
    byt_out="$("$AQL" --force-compile "$suite" 2>&1)"; byt_rc=$?
    if [ "$byt_rc" -ne 0 ]; then
      notes+=("bytecode FAIL(rc=$byt_rc)"); fail=1
    elif [ "$byt_out" != "$int_out" ]; then
      notes+=("bytecode DIVERGES"); fail=1
    else
      notes+=("bytecode ok (== interp)")
    fi
  else
    notes+=("bytecode n/a (uses each)")
  fi

  joined=""; for n in "${notes[@]}"; do joined+="${joined:+  |  }$n"; done
  line="$(printf '%-28s %s' "$name" "$joined")"
  if printf '%s' "${notes[*]}" | grep -q "FAIL\|DIVERGES"; then
    red "$line"
    [ "$int_rc" -ne 0 ] && printf '%s\n' "$int_out" | sed 's/^/    interp| /'
    [ "$chk_rc" -ne 0 ] && printf '%s\n' "$chk_out" | sed 's/^/    check | /'
    [ "${byt_rc:-0}" -ne 0 ] && printf '%s\n' "${byt_out:-}" | sed 's/^/    byte  | /'
    if [ "${byt_rc:-1}" -eq 0 ] && is_compilable "$suite" && [ "${byt_out:-}" != "$int_out" ]; then
      diff <(printf '%s\n' "$int_out") <(printf '%s\n' "${byt_out:-}") | sed 's/^/    diff  /'
    fi
  elif is_compilable "$suite"; then
    green "$line"
  else
    dim "$line"
  fi
done

echo "---"
if [ "$fail" -ne 0 ]; then
  red "FAILED: a suite errored in one of the modes (or interpreter/bytecode diverged)"
  exit 1
fi
green "all suites pass: interpreter + check everywhere, bytecode where compilable (no divergence)"
