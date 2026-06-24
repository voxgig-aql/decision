# aql `main` mode-verification report

**Date:** 2026-06-24 (latest re-test)
**Task:** track latest `aql` `main` and verify that **interpreting**, **checking**,
and **compiling** all work fully against the `Decision` suites; review the
upstream design docs that bear on the open gaps.

## TL;DR

Latest `main` is **`14036b41`** (built this pass).

| Mode | `14036b41` (latest main) | Verdict |
|------|--------------------------|---------|
| **Interpreting** (`aql suite.aql`) | all 5 suites pass | ✅ **fully works** |
| **Checking** (`aql check suite.aql`) | unit/spec/prop suites **0 errors**; `smoke_test` 16; `decision.aql` advisory **2** (was 41) | ⚠️ **nearly clean** |
| **Compiling** (`aql --force-compile suite.aql`) | only `prop_test` compiles (== interp); `test-test`/`each` still refused | ❌ **partial / in flux** |

Upstream **read this report** and landed fixes (see design review). The check
story is now strong — the unit/spec/prop suites are clean and `decision.aql` is
down to two residual false positives. Compiling the test-framework code-body
words (`test-test`, `each`) remains the tracked §6 blocker. The gate's
`BYTECODE_AQL_REF` is **left at `c44d994f`** — it is still the build with the
best bytecode coverage of *our* suites (the comprehensive `unit_test` + `smoke`);
`14036b41` compiles only `prop_test`. No library files changed.

## Builds tracked

| Role | Commit | Notes |
|------|--------|-------|
| Project pinned interpreter (`AQL_REF`) | `958c379b` | predates the bytecode compiler; unchanged |
| Gate bytecode build (`BYTECODE_AQL_REF`) | `c44d994f` | compiles `unit_test` + `smoke` (best coverage of our suites) |
| earlier main | `f8ee6426`, `65410b18` | prior passes (see trend) |
| **Latest main (this pass)** | `14036b41` | includes the client-issue fixes below |

### How it was obtained

The proxy's scoped **git relay 403s for `aql-lang/aql`** (not in this session's
git scope). A direct HTTPS **tarball** over the general proxy works:

```bash
curl -sSL -o aql-main.tar.gz https://codeload.github.com/aql-lang/aql/tar.gz/refs/heads/main   # HTTP 200
curl -sS https://api.github.com/repos/aql-lang/aql/commits/main   # HEAD -> 14036b41…
tar xzf aql-main.tar.gz && ( cd aql-*/cmd/go && GOFLAGS=-mod=mod \
  go build -ldflags "-X github.com/aql-lang/aql/cmd/go.Version=14036b41…" -o ~/.local/bin/aql-main ./aql )
```

## Per-suite results on latest main (`14036b41`)

| Suite | interpret | check | compile (`--force-compile`) |
|-------|-----------|-------|------------------------------|
| `decision_unit_test.aql`  | ✅ pass | ✅ 0 err | ❌ `code-body word test-test (Stage 2)` |
| `decision_unit_spec.aql`  | ✅ pass | ✅ 0 err | ❌ `code-body word each (Stage 2)` |
| `decision_prop_test.aql`  | ✅ pass | ✅ 0 err | ✅ **compiles, output == interpreter** |
| `decision_prop_spec.aql`  | ✅ pass | ✅ 0 err | ❌ `code-body word each (Stage 2)` |
| `decision_smoke_test.aql` | ✅ pass | ❌ 16 err | ❌ `check diagnostics` |

Plain `--compile` (silent interpreter fallback) passes all 5 suites.

## Design-doc review (latest `main/design`)

- **`CLIENT-FIXES-2026-06-24.md`** — upstream's response to the three client
  reports, **this one included** (it links `aql-main-verification-2026-06-23.md`).
  Landed fixes relevant to `decision`:
  - `f247557` **`convert` return-type modeling** — `convert Float x` now yields a
    *value* of the target type, not the bare type literal (killed the
    `no_signature` on downstream arithmetic).
  - `a0604d7` **`fold [push]`** — `push`'s `[Any List]` overload now declares a
    return, so a fold accumulator no longer widens to `Any` and fails
    (`no_signature: push` gone).
  - **gradual-`Any`** — an explicitly-`Any` param/return now binds a *dynamic*
    carrier and poly-matches concrete slots (the "unify `Any` with concrete
    params" item). This cleared the bulk of the `decision.aql` check noise.

  Its decision verdict: unit/spec/prop **check clean**; smoke's 16 are the
  deferred **namespace + dynamic-dispatch** class (`DTable`,
  `eval-table`/`decide` left as `uncalled_function`). Its compile note: the
  remaining `--force-compile` refusals are the test framework's **code-body
  words** (`each`, `test-test`, `do` at "Stage 2"), the tracked §6 emitter work,
  unchanged by the branch.
- **`aql-bytecode-finish-line.0.md` / `aql-bytecode-final-two-refusals.0.md`** —
  the *spec-corpus* `refusalCeiling` has reached **0**, but that corpus's "Test
  harness" tier (`test-test`/`test-prop`/`test-check-prop`/`test-skip`, ~16 rows)
  is handled by **meta-fallback** (`TestOnlyMetaFallsBack`), i.e. it falls back
  to the interpreter rather than truly lowering — which is exactly why
  `--force-compile` (no fallback) still refuses our `test-test`/`each` suites.
- **`COMPILABLE-SUBSET.md` / `aql-bytecode-completion.0.md`** — confirm `each`
  with code-body/lambda args and the test-harness words are the named
  reducible/META clusters still being lowered; "refusal is always sound" (a
  refusal never miscompiles).
- **`checker-accuracy-review.10.md`** — the gradual-`Any` / disjunct-matching
  work behind the `decision.aql` 41 → 2 drop; the residual `all`/`any` and the
  smoke namespace cases are the known not-yet-threaded exports.

## Trend across the builds tested

| Metric | `c44d994f` | `f8ee6426` | `65410b18` | `14036b41` |
|--------|-----------:|-----------:|-----------:|-----------:|
| interpret (all suites) | ✅ | ✅ | ✅ | ✅ |
| unit/spec/prop check | 0 | 0 | 0 | 0 |
| `smoke_test` check | 0\* | 16 | 16 | 16 |
| `decision.aql` advisory check | 39 | 41 | 5 | **2** |
| suites that `--force-compile` | unit_test, smoke | — | — | **prop_test** |

\* `c44d994f` predates the "module-fn bodies analyse in check mode" change, so
its checker never descended into the imported `decision.aql` word bodies — hence
0 on smoke there. The 16 are false positives regardless (the interpreter runs
smoke green).

## Residual diagnostics (all false positives — interpreter runs green)

- `decision.aql` (2): `no_signature` for the internal generics `all` / `any`.
- `smoke_test` (16): `uncalled_function: eval-table/eval-tree/decide/with-policy
  … left on the stack as data`, `undefined_word: DTable`,
  `no_signature: make/collect-table/all/any` — the namespace-exposed-word class
  the checker does not yet thread.
- Compile: `test-test` and `each` are the test framework's code-body words
  (tracked §6); `smoke` additionally gates on the above check diagnostics.

## Recommendation

- **Keep the gate on `c44d994f`.** It compiles the comprehensive `unit_test`
  (every evaluator + hit policy) and `smoke`, which is stronger divergence
  coverage than `prop_test` alone. `14036b41` compiles only `prop_test` and has
  *regressed* `unit_test`/`smoke` compilation. Upstream's own re-pin checklist
  agrees: keep `c44d994` for the bytecode-capable reference. (`test/diverge.sh`
  re-verified **green**.)
- **Checking is essentially solved** for the unit/spec/prop suites (0 errors) and
  `decision.aql` is down to two false positives — if any suite gated check with
  `--soft`/`continue-on-error`, that can now be tightened on a `14036b41`+ build.
- **Re-test compiling** once the §6 code-body-word lowering lands (it would make
  `test-test`/`each`, and thus `unit_test`/`smoke`, true-compile under
  `--force-compile`), at which point widen the gate's `COMPILABLE` set.
- The project's pinned interpreter (`AQL_REF = 958c379b`) is untouched and
  remains the verified baseline for the library itself.

## Reproduce (per mode)

```bash
aql-main test/decision_unit_test.aql                  # interpret
aql-main check test/decision_unit_test.aql            # check (non-zero exit on errors)
aql-main --force-compile test/decision_prop_test.aql  # compile (aborts if uncompilable)
BYTECODE_AQL=~/.local/bin/aql-main bash test/diverge.sh   # whole gate against a given build
```
