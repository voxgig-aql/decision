# aql `main` mode-verification report

**Date:** 2026-06-23
**Task:** download the latest `aql` from `main` and verify that **interpreting**,
**checking**, and **compiling** all work fully against the `Decision` suites.

## TL;DR

| Mode | Latest `main` `f8ee6426` | Verdict |
|------|--------------------------|---------|
| **Interpreting** (`aql suite.aql`) | all 5 suites pass | ✅ **fully works** |
| **Checking** (`aql check suite.aql`) | `smoke_test` 0 → **16** errors; `decision.aql` advisory 39 → **41** | ⚠️ **regressed** |
| **Compiling** (`aql --force-compile suite.aql`) | **no suite** force-compiles | ❌ **does not work** |

**Latest `main` is a net regression** for this library's *check* and *compile*
modes versus the previously-verified bytecode build `c44d994f`. Interpreting is
solid. The gate's `BYTECODE_AQL_REF` was **left at `c44d994f`** (still green); no
repository files were changed by this verification.

## Builds under test

| Role | Commit | Notes |
|------|--------|-------|
| Project pinned interpreter (`AQL_REF`) | `958c379b` | predates the bytecode compiler; unchanged |
| Previously-verified bytecode build (`BYTECODE_AQL_REF`) | `c44d994f` | the gate's pin; compilable suites pass all 3 modes |
| **Latest `main` (this report)** | `f8ee6426` | merge of PR #175 *bytecode-compiler-resources* |

Built from source with `GOFLAGS=-mod=mod go build ./aql` at each ref.

## Per-suite results on latest `main` (`f8ee6426`)

| Suite | interpret | check | compile (`--force-compile`) |
|-------|-----------|-------|------------------------------|
| `decision_unit_test.aql`  | ✅ pass | ✅ 0 err | ❌ `code-body word test-test (Stage 2)` |
| `decision_unit_spec.aql`  | ✅ pass | ✅ 0 err | ❌ `code-body word each (Stage 2)` |
| `decision_prop_test.aql`  | ✅ pass | ✅ 0 err | ❌ `code-body word each (Stage 2)` |
| `decision_prop_spec.aql`  | ✅ pass | ✅ 0 err | ❌ `code-body word each (Stage 2)` |
| `decision_smoke_test.aql` | ✅ pass | ❌ **16 err** | ❌ `check diagnostics` |

Plain `--compile` (silent interpreter fallback) still passes all 5 suites — the
fallback path is intact; only the *strict* `--force-compile` path fails.

## Regression vs `c44d994f` (side-by-side)

| Check | `c44d994f` (pinned gate) | `f8ee6426` (latest main) |
|-------|--------------------------|--------------------------|
| `smoke_test` check error count | **0** | **16** |
| `unit_test` `--force-compile` | compiles + runs (exit 0) | **refused** (`test-test` Stage 2) |
| `decision.aql` advisory check | 39 err, 13 warn | **41 err**, 13 warn |

## Root cause (upstream diff `c44d994f..f8ee6426`)

The two regressions trace to the *checkstate-ownership* and *bytecode-compiler*
work merged in PRs #170–#175:

1. **Checking** — commit `2816e8f3` *"eng: pass-global CheckState ownership —
   module-fn bodies analyse in check mode (§5b)"*. The checker now descends into
   the **imported** `decision.aql` word bodies, where it still cannot trace this
   library's namespace-exposed, dynamically-dispatched words. It therefore emits
   **false-positive** diagnostics it did not before:
   - `undefined_word: DTable`
   - `no_signature` for `all` / `any` / `make` / `collect-table`
   - `uncalled_function: eval-table … matched no signature and was left on the
     stack as data` (also `eval-tree`, `decide`)

   The interpreter runs every one of these green, so they are check-mode
   limitations — the same class of false positive already documented in
   `dx-report.md` (the checker can't trace exports-by-reference), now surfacing
   on more suites because module-fn bodies are analysed.

2. **Compiling** — the bytecode compiler still refuses the **test framework's
   code-body words** (`test-test`, `each`), a tracked upstream blocker
   (design §6, *"compiling the test framework's code-body words"*,
   commit `e55271ab`). At `c44d994f` the compiler accepted the real
   `decision_unit_test.aql` `Test.test` patterns; at `f8ee6426` it reclassified
   them as uncompilable (a trivial single `Test.test` still compiles, but the
   suite's patterns do not). `--force-compile` additionally now gates on check
   diagnostics, so the false check errors cascade into compile failures
   (`smoke_test`).

## Recommendation

- **Do not adopt `f8ee6426`** for the divergence/mode gate. Keep
  `BYTECODE_AQL_REF` at `c44d994f`, where the bytecode-compilable suites pass all
  three modes and the interpreter and bytecode agree byte-for-byte.
  (`test/diverge.sh` re-run after this verification: **green**.)
- **Re-test on a future `main`** once the §6 work ("compiling the test
  framework's code-body words") and the check-mode module-fn analysis settle —
  the namespaced-word false positives are the long-standing `dx-report.md`
  checker gap and should be raised there if not already tracked.
- The project's pinned interpreter (`AQL_REF = 958c379b`) is untouched and
  remains the verified baseline for the library itself.

## Reproduce

```bash
# build a given ref
git -C /tmp/aql-src checkout <ref>
( cd /tmp/aql-src/cmd/go && GOFLAGS=-mod=mod go build -o ~/.local/bin/aql-<ref> ./aql )

# per suite, per mode
aql-<ref> test/decision_unit_test.aql            # interpret
aql-<ref> check test/decision_unit_test.aql      # check  (non-zero exit on errors)
aql-<ref> --force-compile test/decision_unit_test.aql   # compile (aborts if uncompilable)

# the whole gate, against any bytecode-capable build
BYTECODE_AQL=~/.local/bin/aql-<ref> bash test/diverge.sh
```
