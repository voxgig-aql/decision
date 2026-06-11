# Developer-experience report: porting `aql:decision` — notes for improving AQL

**Date:** 2026-06-11
**Builds under test:** `aql-lang/aql` @ `958c379b` (the `main` this library
originally targeted) and `db828ec` (the older ref the sibling bloom-filter/trie
libraries pin). Every finding below was reproduced against the actual binaries;
the commands and output are quoted verbatim.

> **Re-reviewed 2026-06-11 against `main` @ `7193a7d3`.** Upstream responded
> the same day (`1981f601`, *"fix: decision DX report"*): findings **3, 4, 6,
> 8 are fixed**, **5 and 7** got their documentation halves (the `check` lints
> remain open), **2 is partially fixed** (the hint never fires for
> namespace-exposed words — this library's case), and **1 is unchanged**. All
> five test suites pass unchanged on `7193a7d3`, so bumping the pin is
> verified safe — but the bump itself needs a maintainer, because the
> workflow file holding the canonical `AQL_REF` requires `workflow` scope to
> edit (see [the bump checklist](#re-review-status-on-latest-main-7193a7d3)).
> Verified evidence per finding:
> [Re-review: status on latest main](#re-review-status-on-latest-main-7193a7d3).

This report comes out of porting the interpreter's internal `aql:decision`
module into a standalone pure-AQL library. The port itself went well — the
module's AQL source ran as a file module essentially unchanged (see
[What worked well](#what-worked-well)) — so this is **not** a complaint list;
it is the set of language/tooling friction points that cost real time, written
up so they can be fixed at the source.

## How to read this

Each finding is tagged:

- **language-bug** — incorrect or surprising semantics.
- **rough-by-design** — the behaviour is intended and consistent, but the
  ergonomics or diagnostics around it are poor.
- **tooling** — build / version / release / CLI, not the language proper.
- **docs-gap** — works, but the safe path is undiscoverable.

…and a severity for a library author (`high`/`medium`/`low`).

## Priority summary

| # | Finding | Tag | Sev | One-line fix | Status @ `7193a7d3` |
|---|---------|-----|-----|--------------|---------------------|
| 1 | No installable `aql` release — everyone builds from source | tooling | **high** | Tagged releases + prebuilt binaries; unblock `go install` | **open** |
| 2 | A swapped argument order has no "did you mean reordered?" hint — and can silently return a *wrong answer* | rough-by-design | **high** | On signature failure, try arg permutations and say so | **partial** — fires for plain words, not namespaced ones |
| 3 | No first-class key-presence predicate (`has`), and no catch/recover word | language-bug | medium | Add a total `has`/`haskey` Boolean (the missing `get`/`getr` sibling) | **fixed** — `has` shipped |
| 4 | Errors raised across an import boundary lose their filename + source excerpt and leak a `CallAQL:` prefix | language-bug | medium | Render imported-file errors like entry-file errors | **fixed** |
| 5 | `print` forward-collects, so sequential prints emit out of order — silently | rough-by-design | medium | Ship `puts`/`println` (= `print/s`); have `check` flag stranded operands | docs fixed; lint open |
| 6 | `do/error` leaks the caught error on the stack (and `raise`'s own doc example is broken) | rough-by-design | medium | Bind the error as a normal arg; make the construct stack-neutral | **fixed** |
| 7 | `eq` on maps/lists is identity-based — equal literals compare `false`, silently | rough-by-design | medium | `check`-time warning when both `eq` operands are Map/List (esp. a literal) | docs fixed; lint open |
| 8 | `aql -version` reports `0.1.0-dev`, ignoring the embedded VCS revision; skew errors misdirect | tooling | medium | Read `debug.ReadBuildInfo` vcs.revision; better "needs newer aql" hint | **fixed** |

---

## Re-review: status on latest main (7193a7d3)

Re-tested 2026-06-11 against `main` @ `7193a7d3` (39 commits past
`958c379b`), which includes upstream's same-day response commit `1981f601`
(*"fix: decision DX report — do/error stack-neutral, has word,
import-boundary errors, swapped-arg hint, version stamp, doc fixes"*). All
five of this library's test suites pass unchanged on `7193a7d3`, every
AGENTS.md/skill code block re-verified, and `aql check --soft` behaves as
before — so adopting it is safe. Per-finding status, each re-verified
against the freshly built binary:

**1 — open.** Still exactly one tag (`eng/go/v0.0.1`, the kernel sub-module,
not the CLI), and all four `replace` directives remain in `cmd/go/go.mod`,
so `go install …@latest` stays blocked and every consumer still bootstraps
from a pinned clone — this review hand-built yet another one.

**2 — partially fixed.** The proposed permutation probe exists and fires for
plain words, in both the forward and the stack form:

```
$ aql -e 'def wp fn [[p:String t:Map] [Map] [t]] wp {a:1} "collect"'
error: [aql/signature_error]: no matching signature for wp
  = no signature matches (Map, ProperString); one exists for (String, Map)
    — did you swap the arguments? expected: wp p:String t:Map
```

But it never fires for **namespace-exposed words** — and this library
exports everything through `surface`/`exposes`. The report's original repro,
`Decision.with-policy table "collect"`, still fails down the
`uncalled_function` path with a swap-blind hint (*"check the call's argument
types and arity — or use with-policy/r …"* — better than the old grouping
hint, but it doesn't see the reorder). And the dangerous same-typed swap,
`Decision.decide {age:30} table`, still returns the byte-identical
`{ok:false error:"unknown-model-kind"}`, as predicted — no checker can catch
Map/Map. Remaining ask: run the same permutation probe on the
namespaced-dispatch failure path, where real library calls live.

**3 — fixed.** `has` shipped with exactly the proposed semantics: a total
Boolean presence test that distinguishes present-but-`None` from absent,
mirrors `get`'s container table, never raises, and composes in conditions:

```
$ aql -e '{a:None} "a" has'                  # present, value None
true
$ aql -e '{a:1} "b" has'                     # absent
false
$ aql -e 'none "a" has'                      # None parent — total
false
$ aql -e '[{a:1} {b:2}] filter ["a" has]'    # composes
[{a:1}]
```

(Relatedly, `getr`'s absence raise now carries the documented `not_found`
code — `93ebcd40`.) This unblocks the library-side follow-up: the
presence/optional-input conditions this module had to cut are now
expressible.

**4 — fixed.** The same missing-field repro now renders with the imported
file's name, source excerpt, and caret — identical fidelity to entry-file
errors — and the `CallAQL:` prefix is gone:

```
error: [aql/not_comparable]: gte
  --> ./decision.aql:130:396
  130 | def apply-op gen [(T extends Comparable)] fn [[rhs:T op:String lhs:T] …
                                                            ^^^^^ gte
```

**5 — docs fixed; the `check` lint remains open.** Behaviour is unchanged by
design (`"a" print "b" print` still emits `b` then `a`), but
`describe print` now documents the ordering pitfall prominently and
recommends `print/s` or statement terminators for sequences. The proposed
`check` advisory for stranded-then-flushed values is still future work.

**6 — fixed.** `do [ raise "boom" ] error [ "recovered" ]` now leaves
exactly `recovered` — nothing leaks to stdout, and the
`def result do […] error […]` form binds the handler's result, not the
caught error. The broken `dup.got` example in `describe raise` was replaced
with the working `var [[e] …]` form.

**7 — docs fixed; the `check` lint remains open.** Identity semantics are
intentionally kept, but `describe eq`'s notes now lead with
`` `{a:1} eq {a:1}` is `false` `` and close with "in tests, assert maps/lists
with `deq`, not `eq`". The proposed `check`-time warning for Map/List `eq`
operands is still future work.

**8 — fixed.** Dev builds now read the embedded VCS stamp:

```
$ aql -version
aql 0.1.0-dev (git 7193a7d3c698, dirty)
```

**Net:** four findings fully fixed (3, 4, 6, 8), two shipped their
documentation halves with the `check` lints still open (5, 7), one is
partially fixed with a concrete remaining gap (2 — the probe skips
namespace-exposed words), and the release-engineering finding is untouched
(1). The two `high`-severity items are, fittingly, the two still open:
installable releases, and swap diagnostics on the dispatch path real
libraries actually use.

**To adopt the pin** (verified safe; needs a maintainer because
`.github/workflows/test.yml` requires `workflow` scope — finding 1 in
miniature): set the new ref in every lockstep location, then re-run the
suites —

1. `.github/workflows/test.yml` → `AQL_REF: 7193a7d3c69857207e44b4bd53541b9b0d4348aa`
   (the single source of truth the consistency job checks the rest against),
2. `.claude/hooks/session-start.sh` → the same 40-char `AQL_REF`,
3. `api.json` → `"aql_ref": "7193a7d3"`,
4. the short-ref mentions in `README.md` ("pinned commit"), `CLAUDE.md`
   (`AQL_REF =`), and `docs/how-to.md` (the `git checkout` line).

---

## 1. No installable `aql` release — every consumer builds from source · *tooling · high*

> **Re-review @ `7193a7d3`: still open.** See [the re-review](#re-review-status-on-latest-main-7193a7d3); the section below is the original finding, kept as the record.

A downstream pure-AQL library needs a *specific* `aql` binary to run and test
its module (this one requires `958c379b`). There is no tagged release, no
`brew`/binary download, and `go install` is blocked:

```
$ go install github.com/aql-lang/aql/cmd/go/aql@latest
go: ...cmd/go@v0.0.0-20260611024449-958c379b1229: The go.mod file for the module
providing named packages contains one or more replace directives. It must not
contain directives that would cause it to be interpreted differently than if it
were the main module.

$ git -C aql tag
eng/go/v0.0.1          # the ONLY tag — and it's the kernel sub-module, not the CLI
```

So the only bootstrap is `git clone` + `cd cmd/go && make build`, at a commit
that must then be single-sourced across every consumer touchpoint (CI workflow,
SessionStart hook, `api.json`) and re-pinned by hand each time the language
moves. This library already pins a *different* commit than its sibling repos,
multiplying the bookkeeping.

**Suggestion.** (1) Publish prebuilt binaries via tagged GitHub Releases +
goreleaser so non-Go consumers (CI hooks) can `curl` a versioned asset.
(2) Unblock `go install ...@vX.Y.Z`: the two local-path replaces in
`cmd/go/go.mod` (`=> ../../eng/go`, `=> ../../lang/go`) are monorepo-dev only —
move them to a `go.work` file (which `go install` ignores) and require `eng/go`
/ `lang/go` at real tags; the two remaining replaces are dependency *renames*
(`voxgig/struct => voxgig/struct/go`, `voxgiguniversalsdk => voxgig/udk/go`) —
import the real published paths in code so no rename is needed. (3) Cut semver
tags for the CLI module so `@latest` resolves.

---

## 2. A swapped argument order has no diagnostic — and can silently return a wrong answer · *rough-by-design · high*

> **Re-review @ `7193a7d3`: partially fixed — the hint fires for plain words but not namespace-exposed ones.** See [the re-review](#re-review-status-on-latest-main-7193a7d3); the section below is the original finding, kept as the record.

The receiver/model-first convention reads naturally but is easy to invert, and
inverting it produces one of three unhelpful symptoms depending on the arg
types. We mis-ordered `decide`, `eval-cond`, and `with-policy` several times.
The dangerous one is same-typed params:

```
# Decision.decide takes (model, input), both Map. Swap them:
Decision.decide {age:30} table     # => {"error": "unknown-model-kind", "ok": false}
```

That output is **byte-identical to a legitimate** `unknown-model-kind` result —
exit code 0, and `aql check` is clean — so a swapped call looks like a real
domain error and you debug the wrong thing. With distinct types it's instead a
silent no-dispatch:

```
$ aql check -e '... Decision.with-policy table "collect"'   # args swapped (Map, String)
check: [error] uncalled_function: call to 'with-policy' matched no signature
       and was left on the stack as data (arguments: Map, ProperString)
```

The checker prints the *actual* arg types and `describe` knows the declared sig
`[String Map]` — yet the only structural hint offered is "forward args may have
run into the next word; group with parens", which points at parsing and is the
wrong fix.

**Suggestion.** When a call matches no signature, run a cheap permutation check
of the actual arg-type tuple against each declared sig; on a reorder match, emit
a dedicated hint — *"no signature matches (Map, String); one exists for (String,
Map) — did you swap arguments? expected: `with-policy policy:String table:Map`"*
— and suppress the misleading grouping hint. For genuinely same-typed params
(Map/Map) the checker can't tell, so also document encouraging
positionally-distinct nominal types (e.g. `refine Record` `Model` vs `Input`) so
dispatch can distinguish them.

---

## 3. No first-class key-presence predicate, and no catch/recover word · *language-bug · medium*

> **Re-review @ `7193a7d3`: fixed — `has` shipped.** See [the re-review](#re-review-status-on-latest-main-7193a7d3); the section below is the original finding, kept as the record.

A decision condition wants to ask "is this field present?" (DMN-style optional
inputs). It can't be expressed, because there is no way to distinguish *absent*
from *present-but-`None`*, and no Boolean presence test:

```
$ aql -e '{a:1}    "b" get'    # absent
None
$ aql -e '{a:None} "a" get'    # present, value is None
None
$ aql -e '{a:1} "a" has'       # and there is no presence word
error: [aql/undefined_word]: undefined word: has      # same for haskey, has-key, in, member
```

`getr` *can* tell them apart, but it **raises** rather than returning a Boolean —
and there is no `try`/`catch`/`recover`/`rescue` word anywhere in `aql describe`
to turn that raise into a predicate. So the whole class of presence/optional
conditions had to be cut from the decision tables/trees (the module's own
`api.json` documents the surrender).

**Suggestion.** Add a total Boolean `has` (alias `haskey`): `{a:None} "a" has`
→ `true`, `{a:1} "b" has` → `false` — "the key is bound, regardless of value".
Mirror `get`'s signature table (String/Atom key over Map/Object/Store; Integer
index over List/Array) and return `false` (never raise) on a `None` parent, so
it composes inside `if`/`filter`/conditions. It is the missing third member of
the `get` (None on miss) / `getr` (raise on miss) family — and its
implementation is the lookup `getr` already does, returning ok/err as a Boolean.
(Lower priority: a `try`/recover primitive would also let userland downgrade any
raise to a value.)

---

## 4. Errors across an import boundary lose their location · *language-bug · medium*

> **Re-review @ `7193a7d3`: fixed.** See [the re-review](#re-review-status-on-latest-main-7193a7d3); the section below is the original finding, kept as the record.

An error raised inside an *imported* file renders far worse than the same error
in the entry file. Evaluating a condition against an input missing the queried
field (very common) aborts with:

```
error: CallAQL: [aql/not_comparable]: gte
  --> 130:396
```

`130:396` points into a long one-line definition of an imported file that is
**not named**, with **no source excerpt** — you can't tell which of 14 exported
functions failed or on which field. The same raise in the *entry* file gets the
normal treatment (excerpt + caret). Worse, the language's *own* comparison error
is genuinely good — and it too collapses across an import:

```
# direct, entry file — actionable:
error: [aql/incomparable]: gte: cannot order None and Integer
  = different types with no shared ordering; use tcmp for a cross-type total order

# the identical error, raised from inside an imported file — location lost, prefix leaked:
error: CallAQL: [aql/incomparable]: gte: cannot order None and Integer
  --> 1:40
```

**Suggestion.** Render imported-file runtime errors with the same fidelity as
entry-file errors: `--> decision.aql:130:396` plus the source-line excerpt and
caret, and drop the internal-sounding `CallAQL:` prefix (or replace it with a
real call-site frame). This helps *every* error that crosses an import boundary.
(Separately, the bare `gte` body here is partly the library's doing — its
`raise not_comparable op` passes only the op string instead of the
field/operands — but the location-rendering gap is the language's.)

---

## 5. `print` forward-collects, so sequential prints emit out of order — silently · *rough-by-design · medium*

> **Re-review @ `7193a7d3`: docs fixed; `check` lint still open.** See [the re-review](#re-review-status-on-latest-main-7193a7d3); the section below is the original finding, kept as the record.

`print` looks ahead for its argument, so each `print` grabs the *next*
statement's value and the leftovers flush at program end:

```
$ aql /tmp/p.aql        # source:  "a" print  "b" print
b
a
$ aql /tmp/p3.aql       # three statements, one print each (no `end`)
b
c
a                       # not even a clean reverse
```

It never errors and `aql check` says nothing, so it silently scrambles any
test/smoke/doc snippet that prints a sequence of values — and a 3-way scramble
makes "is my expected output right?" unreliable. The clean fix already exists
but is undiscoverable:

```
$ aql /tmp/ps.aql       # "a" print/s  "b" print/s  "c" print/s   (stack-only modifier)
a
b
c
$ aql describe print    # …never mentions /s or the ordering pitfall
print — Print a value to stdout followed by a newline.  Precedence: forward …
```

**Suggestion.** Ship a non-collecting `puts`/`println` defined as `print/s` (or
have `describe print` recommend `print/s` / `print … end` for sequences). And
extend `check`: the existing `forward_strands_operand` advisory ignores 1-arg
forward-only words like `print`; make it fire when a forward word strands *any*
value at a statement boundary that is later flushed unconsumed.

---

## 6. `do/error` leaks the caught error on the stack · *rough-by-design · medium*

> **Re-review @ `7193a7d3`: fixed.** See [the re-review](#re-review-status-on-latest-main-7193a7d3); the section below is the original finding, kept as the record.

The natural recovering wrapper `do [ …risky… ] error [ fallback ]` silently
leaves the caught error on the stack *beneath* the handler's result — so the
next `def`/sig-match binds the wrong value, or the error auto-prints:

```
$ aql -e 'do [ raise "boom" ] error [ "recovered" ]'
error(boom) recovered                         # the error leaked onto stdout

$ aql /tmp/r12.aql       # def result do [ raise "boom" ] error [ "recovered" ]   result print
recovered
error(boom)              # `def result` bound the top; error(boom) leaked beneath and auto-printed
```

The happy path `do [ 42 ] error [ … ]` is stack-neutral (leaves just `42`), so
the error branch's extra value is an asymmetry you only discover via a stray
`error(...)` or a downstream mismatch — no diagnostic. The correct form,
`error [ var [[e] … ] ]`, has to be known in advance.

**Bonus bug:** `raise`'s own documented example is broken —
`do [raise {…got:42}] error [dup.got print]` raises `signature_error: no
matching signature for dup` (because `dup.got` parses as `dup get got`). The
working forms are `error [ get got print ]` or `error [ var [[e] e.got print ] ]`.

**Suggestion.** Make the handler receive the caught error as a normal bound
argument (the `var [[e] …]` binding becomes the default) and make `do/error`
leave exactly one value — the handler's result — mirroring the happy path. Fix
or remove the broken `dup.got` doc example.

---

## 7. `eq` on maps/lists is identity-based — equal literals compare `false` · *rough-by-design · medium*

> **Re-review @ `7193a7d3`: docs fixed; `check` lint still open.** See [the re-review](#re-review-status-on-latest-main-7193a7d3); the section below is the original finding, kept as the record.

Comparing two structurally-equal maps with `eq` is `false` — at top level,
inside an fn body, and inside an `each`/`var` body alike (we initially suspected
a scope-dependent flip; there is none — it's consistently `false`):

```
$ aql /tmp/eq.aql
top  : false        # ({a:1} eq {a:1})
fn   : false        # same, inside an fn body
each : [false]      # same, inside each/var
deq  : true         # deq is the structural compare
```

This is documented (`describe eq`: "Compound values compare by IDENTITY … use
`deq`") and intentional — but a property test naturally writes
`result eq {hit:"first"}`, which reads as obviously true and silently yields
`false`. Every map assertion in the test suite had to be rewritten to extract a
scalar field first.

**Suggestion.** Keep the semantics, but add a `check`-time warning when both
`eq`/`neq` operands are statically Map- or List-typed (the `x eq {literal}` case
is almost always a mistake and is cheaply detectable): *"`eq` on Map compares by
identity; did you mean `deq`?"* Surface the `{a:1} eq {a:1} => false` / `deq =>
true` pair in `describe eq`'s examples, and consider a `Test`/`Assert`
deep-equal helper so test authors stop re-inventing the per-field workaround.

---

## 8. `aql -version` hides the build commit; skew errors misdirect · *tooling · medium*

> **Re-review @ `7193a7d3`: fixed.** See [the re-review](#re-review-status-on-latest-main-7193a7d3); the section below is the original finding, kept as the record.

A stale `aql` on PATH silently lacked newer words, and `-version` couldn't
disambiguate the build — everything not `make publish`'d reads `0.1.0-dev`, even
though the Go toolchain already embeds the revision:

```
$ aql -version
aql 0.1.0-dev
$ go version -m $(which aql) | grep vcs
	build	vcs.revision=958c379b12295652c739a88f2f198726d48897fb
	build	vcs.modified=true            # aql just never reads this
```

And when you *do* run an older build, the version-skew error misdirects — it
reads as a quoting mistake in your code, never "this word is newer than your
binary":

```
$ aql-db828ec -e 'def C surface {…}'
error: [aql/undefined_word]: undefined word: surface
  = did you mean `def … (surface)` to bind its value, or `def … surface/q` …?
```

**Suggestion.** In the `-version` path, when `Version == "0.1.0-dev"`, fall back
to `debug.ReadBuildInfo()` and append the VCS stamp (e.g. `aql 0.1.0-dev (git
958c379b, dirty)`); stop hardcoding `VERSION := 0.1.0-dev` for dev builds. Make
the `undefined_word` "did you mean (x)/x/q" hint fire only when a same-named
binding plausibly exists; otherwise emit a neutral *"'surface' is not defined in
this build — it may be a newer language word; check `aql describe` or upgrade
aql."* (Higher-effort: let `aql.jsonic` declare a minimum engine revision so
`import`/`check` can fail with *"requires aql ≥ <rev>"*.)

---

## Library-side notes (not language issues)

These tripped the port too, but they are decision-module *design* choices, not
AQL problems — recorded so they aren't mistaken for language bugs:

- **Evaluators take the model first, the input second** (`decide model input`).
  A convention, not a language rule. (It's the *diagnostic* when you get it
  wrong that's the language issue — see finding 2.)
- **Unary ops (`is_null`/`is_not_null`) are unreachable through `eval-cond`** —
  `eval-cond` always supplies a `value`, so a unary op there raises. This is
  downstream of the missing `has` predicate (finding 3); the module simply can't
  express a presence condition. *(Update: `has` shipped in `7193a7d3`, so this
  is now a library to-do rather than a language blocker.)*
- **`make-rule` requires a `Map` `then`** while `make-leaf` accepts any result —
  a builder being stricter than its generic type, a module choice.
- **A "miss" is a value** (`{ok:false error:"…"}`), not a throw — a good pattern,
  noted because a hit has *no* `ok`/`error` fields (inspect `result.error`).

## What worked well

- **The native module's AQL *is* the library.** `aql:decision` is implemented
  as an embedded AQL source string with a thin Go loader; that source ran as a
  standalone file module with **zero changes** (only a header added). That the
  same AQL works as a built-in module and a vendored file is a real strength of
  the design.
- **`refine Record` + generics + `surface`/`exposes`** expressed the typed
  decision records (Cond/Pred/Rule/DTable/DTree, the `Comparable` surface)
  cleanly and read well.
- **Loud-over-silent comparison** (raising on `None` ordering instead of
  returning a silent `false`) is the right call — the issue (finding 4) is the
  error's *location rendering*, not the policy.
- The safe primitives all **exist** — `print/s`, `deq`, `getr` — the gaps are
  discoverability (`describe`) and diagnostics (`check`), which are cheap to
  close.

## Bottom line

The language is clearly capable — a non-trivial DSL module ported to a
standalone library with no algorithm changes. The friction was almost entirely
in **diagnostics and tooling**: a swapped argument, a missing key, or a
cross-import raise all fail in ways that point at the wrong cause, and the
toolchain can't be installed or version-identified without ceremony. The two
highest-leverage fixes — installable releases (1) and reorder-aware signature
diagnostics (2) — would remove most of the time this port lost, and the
`check`-time lints proposed in 5/7 would convert today's silent footguns into
actionable warnings.
