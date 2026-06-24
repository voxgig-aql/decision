# CLAUDE.md

This repository is the `Decision` decision-logic library, written in AQL.

## Using the library

See @AGENTS.md for how to call the `Decision` API correctly from AQL — the
calling convention, the full API, copy-paste idioms, and the common
mistakes to avoid. Every example there is verified against the pinned
`aql` build.

## Working on this repository

- A SessionStart hook (`.claude/settings.json` →
  `.claude/hooks/session-start.sh`) builds `aql` from the pinned commit in
  remote sessions, so a fresh session can run the suites. Locally, build it
  once from source (there is no tagged release and `go install …/aql@latest`
  is blocked by replace directives) — see
  [docs/how-to.md](docs/how-to.md#install-and-run-aql).
- Tests live in `test/`, named `decision_<unit|prop>_<test|spec>.aql` plus a
  `decision_smoke_test.aql`: `_test` = imperative (`Test.test`/`Test.check-prop`),
  `_spec` = declarative spec; `unit` = example-based, `prop` = property-based.
  Each assertion-bearing suite ends by asserting `Test.fail-count` is `0` and
  prints `all green`; the smoke suite carries no assertion (pass = no error).
- `test/diverge.sh` is the multi-mode test gate and **tracks the latest `aql`
  from `main`** (AQL is on an iterative-improvement track — no fixed "best" pin).
  It runs every suite under the interpreter, the checker (`aql check`), and the
  bytecode compiler (`--force-compile`). Hard invariants: every suite interprets
  and checks (zero errors) clean, and every suite the compiler *accepts* matches
  the interpreter byte-for-byte (no divergence). Check became a hard gate once the
  checker reached zero false positives on this library (aql main `0b010ae`). The
  compilable subset is auto-detected; compile coverage is reported as current status.
  It builds the latest `main` HEAD by default (override with `BYTECODE_AQL` or
  `BYTECODE_AQL_REF`); the project's pinned `AQL_REF` is only the interpreter
  baseline. See
  [docs/how-to.md](docs/how-to.md#run-the-suites-under-every-execution-mode).
- Known AQL-runtime gotchas observed with the pinned build are in
  `dx-report.md`. The pinned aql commit is single-sourced in `.github/workflows/test.yml`
  (`AQL_REF` = `958c379b`); a CI job fails if the hook or `api.json` drift from it.
