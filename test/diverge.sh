#!/usr/bin/env bash
# Multi-mode test gate — tracks the LATEST boru from `main`.
#
# boru is on an iterative-improvement track, so this gate always targets the
# newest `boru` and reports current status rather than pinning a "best" build.
# It runs every suite under all three execution modes:
#
#   * INTERPRETER  — `boru suite.aql`            (the supported path)
#   * CHECK        — `boru check suite.aql`      (static type-checker)
#   * BYTECODE     — `boru --force-compile suite.aql`
#                    (compiles to the kernel VM; ABORTS if it can't lower the
#                    program faithfully — never a silent fallback)
#
# Three invariants are HARD (a violation fails the gate):
#   1. the interpreter passes every suite;
#   2. the checker (`boru check`) reports zero errors on every suite;
#   3. every suite the bytecode compiler ACCEPTS produces output byte-identical
#      to the interpreter — i.e. the two engines never diverge.
#
# The checker reached zero false positives on this library as of boru `main`
# `0b010ae` (design/CLIENT-VERIFICATION-MAIN-2026-06-24.md), so `check` is now a
# real gate — a regression on a newer `main` is a signal worth failing on.
#
# Compile COVERAGE is the one thing reported as current STATUS, because it moves
# as boru improves and is outside this repo's control: which suites the compiler
# accepts (the test-framework code-body words `test-test` / `each` and the smoke
# dynamic-help `check diagnostics` artifact are still being lowered upstream).
# The compilable subset is auto-detected, so as more suites start compiling they
# are divergence-checked automatically — no edit needed here.
#
# Resolving the boru build (latest main by default):
#   1. $BYTECODE_AQL, if set and it accepts --force-compile;
#   2. else build $BYTECODE_BORU_REF (default: current `main` HEAD), cached by
#      sha in ~/.local/bin. The proxy git relay is scoped, so the source is
#      fetched as an HTTPS tarball from codeload. Requires `go` (+ network on a
#      new sha);
#   3. else (offline) the on-PATH `boru`, or the newest cached build, if either
#      accepts --force-compile.
#
# Run from anywhere:
#   bash test/diverge.sh
#   BYTECODE_AQL=/path/to/boru bash test/diverge.sh     # use a specific binary
#   BYTECODE_BORU_REF=<sha>     bash test/diverge.sh     # pin a specific commit
set -uo pipefail

cd "$(dirname "$0")/.."   # repo root, so `import "./decision.aql"` resolves

BYTECODE_BORU_REF="${BYTECODE_BORU_REF:-}"   # empty => resolve latest main HEAD
API_MAIN="https://api.github.com/repos/boru-lang/boru/commits/main"
TARBALL="https://codeload.github.com/boru-lang/boru/tar.gz"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n'  "$*"; }

supports_force_compile() {
  [ -n "${1:-}" ] && command -v "$1" >/dev/null 2>&1 && "$1" --force-compile -e '1 2 add' >/dev/null 2>&1
}

latest_main_sha() { curl -fsS "$API_MAIN" 2>/dev/null | grep -m1 '"sha"' | sed -E 's/.*"sha": *"([0-9a-f]+)".*/\1/'; }

# Build boru at $1 (a full sha) into a sha-named cache binary; echo its path.
build_ref() {
  local ref="$1" bin="$HOME/.local/bin/boru-bytecode-${1:0:12}"
  if supports_force_compile "$bin"; then echo "$bin"; return 0; fi
  command -v go >/dev/null 2>&1 || { red "no \`go\` toolchain; cannot build boru @ ${ref:0:12} (see docs/how-to.md)"; return 1; }
  red "building boru @ ${ref:0:12} (one-time; cached)…" >&2
  local d; d="$(mktemp -d)"
  if curl -fsSL "$TARBALL/$ref" | tar -xz -C "$d" --strip-components=1 \
     && ( cd "$d/cmd/go" && GOWORK=off GOFLAGS=-mod=mod go build \
            -ldflags "-X github.com/boru-lang/boru/cmd/go.Version=$ref" -o "$bin" ./boru ); then
    rm -rf "$d"; echo "$bin"; return 0
  fi
  rm -rf "$d"; red "build failed (see docs/how-to.md)"; return 1
}

newest_cached_bytecode_aql() {
  local b; for b in $(ls -t "$HOME/.local/bin/boru-bytecode-"* 2>/dev/null); do
    supports_force_compile "$b" && { echo "$b"; return 0; }
  done; return 1
}

resolve_aql() {
  if supports_force_compile "${BYTECODE_AQL:-}"; then echo "$BYTECODE_AQL"; return 0; fi
  local ref="$BYTECODE_BORU_REF"
  [ -z "$ref" ] && ref="$(latest_main_sha)"
  if [ -n "$ref" ]; then build_ref "$ref" && return 0; fi
  # Offline fallback (couldn't reach main to resolve/build latest): prefer the
  # NEWEST cached bytecode build — the best proxy for "latest" — over a possibly
  # stale on-PATH `boru`. Warn, because this may not be the true HEAD.
  local b
  if b="$(newest_cached_bytecode_aql)"; then
    red "note: could not reach boru main; using newest cached build ($(basename "$b")) — may lag HEAD" >&2
    echo "$b"; return 0
  fi
  supports_force_compile boru && { red "note: could not reach boru main; using on-PATH boru — may lag HEAD" >&2; command -v boru; return 0; }
  return 1
}

AQL="$(resolve_aql)" || { red "could not resolve a bytecode-capable boru (no network and no cached build)"; exit 2; }
supports_force_compile "$AQL" || { red "resolved boru rejects --force-compile: $AQL"; exit 2; }
green "boru: $("$AQL" -version 2>/dev/null || echo "$AQL")"
echo

SUITES=(
  test/decision_unit_test.aql
  test/decision_unit_spec.aql
  test/decision_prop_test.aql
  test/decision_prop_spec.aql
  test/decision_smoke_test.aql
)

fail=0          # hard failures: interpreter error, or a compiled suite diverging
compiled=0      # how many suites the compiler accepted (status)
checkclean=0    # how many suites checked with 0 errors (status)
for suite in "${SUITES[@]}"; do
  name="${suite#test/}"; notes=()

  int_out="$("$AQL" "$suite" 2>&1)"; int_rc=$?
  if [ "$int_rc" -eq 0 ]; then notes+=("interp ok"); else notes+=("interp FAIL(rc=$int_rc)"); fail=1; fi

  chk_out="$("$AQL" check "$suite" 2>&1)"; chk_rc=$?
  cerr="$(printf '%s' "$chk_out" | grep -oE '[0-9]+ error\(s\)' | head -1)"; cerr="${cerr% error(s)}"; cerr="${cerr:-?}"
  if [ "$chk_rc" -eq 0 ]; then notes+=("check ok"); checkclean=$((checkclean+1)); else notes+=("check FAIL(${cerr} err)"); fail=1; fi

  byt_out="$("$AQL" --force-compile "$suite" 2>&1)"; byt_rc=$?
  if [ "$byt_rc" -eq 0 ]; then
    compiled=$((compiled+1))
    if [ "$byt_out" = "$int_out" ]; then notes+=("compile ok (== interp)"); else notes+=("compile DIVERGES"); fail=1; fi
  else
    notes+=("compile n/a (refused)")
  fi

  joined=""; for n in "${notes[@]}"; do joined+="${joined:+  |  }$n"; done
  line="$(printf '%-28s %s' "$name" "$joined")"
  if printf '%s' "${notes[*]}" | grep -q "FAIL\|DIVERGES"; then
    red "$line"
    [ "$int_rc" -ne 0 ] && printf '%s\n' "$int_out" | sed 's/^/    interp| /'
    [ "$chk_rc" -ne 0 ] && printf '%s\n' "$chk_out" | grep -iE "error\]" | sed 's/^/    check | /'
    if [ "$byt_rc" -eq 0 ] && [ "$byt_out" != "$int_out" ]; then
      diff <(printf '%s\n' "$int_out") <(printf '%s\n' "$byt_out") | sed 's/^/    diff  /'
    fi
  else
    green "$line"
  fi
done

echo "---"
dim "status: ${checkclean}/${#SUITES[@]} suites check-clean; ${compiled}/${#SUITES[@]} suites compile (divergence-checked); the rest are upstream-pending."
if [ "$fail" -ne 0 ]; then
  red "FAILED: an interpreter or check error, or a compiled suite diverged from the interpreter"
  exit 1
fi
green "OK: every suite interprets and checks clean; no interpreter/bytecode divergence on any compiled suite"
