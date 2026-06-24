# How-to guides

Task-oriented recipes. Each one assumes you already know roughly what a
decision table or tree is; if not, start with the [Tutorial](tutorial.md).
For the *why* behind any of these, follow the links into the
[Explanation](explanation.md); for exact signatures, the
[Reference](reference.md).

- [Install and run aql](#install-and-run-aql)
- [Choose between a table and a tree](#choose-between-a-table-and-a-tree)
- [Build a table from rules](#build-a-table-from-rules)
- [Use compound conditions](#use-compound-conditions)
- [Pick a hit policy](#pick-a-hit-policy)
- [Build a decision tree](#build-a-decision-tree)
- [Handle a no-match or an error](#handle-a-no-match-or-an-error)
- [Use it from your own script](#use-it-from-your-own-script)
- [Run the tests](#run-the-tests)

---

## Install and run aql

The module is written in AQL, which has no tagged release yet, so build
the interpreter from source (the documented `go install …/aql@latest`
fails on the repo's replace directives):

```bash
git clone https://github.com/aql-lang/aql /tmp/aql-source
cd /tmp/aql-source
git checkout 958c379b12295652c739a88f2f198726d48897fb   # the commit CI pins (.github/workflows/test.yml AQL_REF)
cd cmd/go
GOFLAGS=-mod=mod go build -o "$HOME/.local/bin/aql" ./aql
```

Make sure `$HOME/.local/bin` is on your `PATH`, then check it:

```bash
aql -version
```

Run any script in this repo by passing its path. The relative
`import "./decision.aql"` resolves against the working directory, so run
from the repo root:

```bash
aql test/decision_smoke_test.aql
```

This module needs aql ≥ `958c379b` — it uses `surface`/`exposes`,
generics, `refine Record`, and `fnsig`, and imports no `aql:*`
dependencies. The CI workflow (`.github/workflows/test.yml`) pins the
same commit.

---

## Choose between a table and a tree

Both models map an input `Map` to a result, and `Decision.decide` runs
either one — but they fit different problem shapes:

- A **table** is a flat list of `when → then` rules, evaluated under a
  [hit policy](#pick-a-hit-policy). Reach for it when your rules are
  independent and you want first-match routing, a uniqueness check, or
  to collect every match. This is the common case.
- A **tree** is branch and leaf nodes wired by id. Reach for it when a
  later question only makes sense after an earlier one — "is the
  applicant an adult? *then* check their score" — i.e. genuinely nested
  decisions where a flat table would repeat the same guard on every row.

If in doubt, start with a table; promote to a tree only when you find
yourself duplicating a leading condition across many rules. The two
models share the same condition vocabulary, so the conditions you write
carry over either way.

---

## Build a table from rules

A rule pairs a `when` condition with a `then` result. `make-rule` builds
one, `make-table` collects them (defaulting to the `"first"` hit
policy), and `decide` evaluates the table against an input — **model
first, input second**:

```aql
import "./decision.aql"
def rules [
  (Decision.make-rule {field:"age" op:"lt"  value:18} {category:"minor"})
  (Decision.make-rule {field:"age" op:"gte" value:65} {category:"senior"})
  (Decision.make-rule {field:"age" op:"gte" value:18} {category:"adult"})
]
def table (Decision.make-table rules)
print (Decision.decide table {age:12}) end   # => {category: minor}
print (Decision.decide table {age:70}) end   # => {category: senior}
print (Decision.decide table {age:30}) end   # => {category: adult}
```

Rule **order matters** under the default `"first"` policy: `age 70`
matches both the `gte 65` and the `gte 18` rules, but the senior rule is
listed first, so it wins. Put your most specific rules first.

A condition is `{field op value}`. `field` names the input key, `op` is
one of `eq neq lt lte gt gte` (binary) — and `value` is what to compare
against. The `make-rule` builder only sets `when` and `then`; you can
write a rule as a plain Map literal too, since the evaluators only read
fields.

> A condition's `field` is the *key name* the evaluator looks up in the
> input — a String inside a Map literal (`field:"age"`), or an Atom
> (`age/q`) when you use the `Decision.cond` builder.

---

## Use compound conditions

A single `{field op value}` test is often not enough. `all-of`,
`any-of`, and `not-of` combine conditions into a predicate that a rule's
`when` accepts directly. Build the leaf conditions with `Decision.cond`
(its `field` is an Atom — quote bare names with `/q`):

```aql
import "./decision.aql"
def adult (Decision.cond age/q   "gte" 18)
def high  (Decision.cond score/q "gte" 90)

# all-of: EVERY child must hold
def rule (Decision.make-rule (Decision.all-of [adult high]) {tier:"premium"})
def tbl (Decision.make-table [rule])
print (Decision.decide tbl {age:25 score:95}) end   # => {tier: premium}
print (Decision.decide tbl {age:25 score:50}) end   # => {ok:false error:no-match}
```

`any-of` holds when **at least one** child does, and `not-of` negates a
single condition:

```aql
import "./decision.aql"
def adult (Decision.cond age/q   "gte" 18)
def high  (Decision.cond score/q "gte" 90)

def any-tbl (Decision.make-table [(Decision.make-rule (Decision.any-of [adult high]) {ok:"yes"})])
print (Decision.decide any-tbl {age:10 score:95}) end   # => {ok: yes}

def not-tbl (Decision.make-table [(Decision.make-rule (Decision.not-of (Decision.cond age/q "lt" 18)) {adult:true})])
print (Decision.decide not-tbl {age:25}) end            # => {adult: true}
```

You can also write a predicate as a Map literal — a compound condition
is just `{kind:"group" op:"all"|"any"|"not" children:…}` — which is what
the builders produce. Predicates nest: an `all-of` child may itself be
an `any-of`, to any depth.

> **Keep ordered fields present.** `lt/lte/gt/gte` require a Comparable
> value, and a missing field reads as `None`, which is not Comparable —
> so an ordering op on an absent field **raises** `not_comparable`
> rather than returning false. `eq`/`neq` tolerate a missing field
> (they just compare unequal). If a field may be absent and you need an
> ordering test, guarantee the field is present in the input, or filter
> those inputs out before deciding. See
> [Handle a no-match or an error](#handle-a-no-match-or-an-error).

---

## Pick a hit policy

A table's **hit policy** decides what happens when zero, one, or many
rules match. `make-table` defaults to `"first"`; `with-policy` returns a
copy of a table under a different policy. There are four:

```aql
import "./decision.aql"
def rules [
  (Decision.make-rule {field:"score" op:"lt"  value:50} {grade:"fail"})
  (Decision.make-rule {field:"score" op:"gte" value:50} {grade:"pass"})
]

# "first" (default): the first matching rule's then
def first-tbl (Decision.make-table rules)
print (Decision.decide first-tbl {score:75}) end   # => {grade: pass}
```

**`"unique"`** expects exactly one match. Zero matches give
`{ok:false error:"no-match"}`; two or more give
`{ok:false error:"multiple-matches"}` — use it to assert your rules are
mutually exclusive:

```aql
import "./decision.aql"
def utbl (Decision.with-policy "unique" (Decision.make-table [
  (Decision.make-rule {field:"score" op:"lt"  value:50} {grade:"fail"})
  (Decision.make-rule {field:"score" op:"gte" value:50} {grade:"pass"})
]))
print (Decision.decide utbl {score:75}) end   # => {grade: pass}

# overlapping rules under "unique" -> multiple-matches
def overlap (Decision.with-policy "unique" (Decision.make-table [
  (Decision.make-rule {field:"score" op:"gte" value:50} {a:1})
  (Decision.make-rule {field:"score" op:"gte" value:0}  {b:2})
]))
print (Decision.decide overlap {score:75}) end   # => {ok:false error:multiple-matches}
```

**`"collect"`** returns a **List** of every matching rule's `then` —
useful for tagging, where several labels can apply at once:

```aql
import "./decision.aql"
def tags (Decision.with-policy "collect" (Decision.make-table [
  (Decision.make-rule {field:"age"   op:"gte" value:18} {tag:"adult"})
  (Decision.make-rule {field:"score" op:"gte" value:50} {tag:"passing"})
]))
print (Decision.decide tags {age:25 score:80}) end   # => [{tag: adult}, {tag: passing}]
```

**`"priority"`** returns the matching rule with the highest `priority`
field (default `0`). `priority` is a **top-level** field on the rule,
alongside `when`/`then` — and since `make-rule` only sets `when`/`then`,
write priority rules as Map literals:

```aql
import "./decision.aql"
def ptbl (Decision.with-policy "priority" (Decision.make-table [
  {when:{field:"score" op:"gte" value:50} then:{tier:"standard"} priority:1}
  {when:{field:"score" op:"gte" value:90} then:{tier:"premium"}  priority:5}
]))
print (Decision.decide ptbl {score:95}) end   # => {tier: premium}   (priority 5 beats 1)
print (Decision.decide ptbl {score:60}) end   # => {tier: standard}  (only rule 1 matches)
```

---

## Build a decision tree

A tree walks from a root branch node, following the first branch whose
`when` holds, until it reaches a leaf. Build it with the node builders —
`make-branch`, `make-leaf`, `make-tree` — whose ids are **Atoms** (quote
bare names with `/q`):

```aql
import "./decision.aql"
def root-node (Decision.make-branch root/q [
  {when:{field:"age" op:"lt"  value:18} next:"minor"}
  {when:{field:"age" op:"gte" value:18} next:"adult"}
])
def minor-leaf (Decision.make-leaf minor/q "too-young")
def adult-leaf (Decision.make-leaf adult/q "welcome")
def tree (Decision.make-tree root/q [root-node minor-leaf adult-leaf])

print (Decision.decide tree {age:40}) end   # => welcome
print (Decision.decide tree {age:12}) end   # => too-young
```

A branch's `next` names the id of the node to visit when its `when`
holds; a leaf's `result` is whatever value you want returned. Trees
chain naturally — a branch can point at another branch — which is the
reason to reach for a tree over a table. The same model written as a
multi-level Map literal:

```aql
import "./decision.aql"
def tree {kind:"tree" root:"check-age" nodes:[
  {id:"check-age" kind:"branch" branches:[
    {when:{field:"age" op:"lt"  value:18} next:"reject"}
    {when:{field:"age" op:"gte" value:18} next:"check-score"}
  ]}
  {id:"check-score" kind:"branch" branches:[
    {when:{field:"score" op:"gte" value:80} next:"approve"}
    {when:{field:"score" op:"lt"  value:80} next:"review"}
  ]}
  {id:"reject"  kind:"leaf" result:"rejected"}
  {id:"approve" kind:"leaf" result:"approved"}
  {id:"review"  kind:"leaf" result:"needs-review"}
]}
print (Decision.decide tree {age:25 score:90}) end   # => approved
print (Decision.decide tree {age:25 score:60}) end   # => needs-review
print (Decision.decide tree {age:10 score:90}) end   # => rejected
```

Note that ids inside Map-literal branches/leaves are Strings
(`id:"reject"`, `next:"reject"`), while the builders take Atoms
(`reject/q`). The evaluator compares them as strings, so either spelling
works — just be consistent within one tree.

---

## Handle a no-match or an error

Evaluators **never throw on a miss**. A successful evaluation returns the
matching `then`/leaf result; a miss or a structural problem returns an
error Map `{ok:false error:"…"}`. A genuine result has no `ok` field, so
the way to detect a miss is to test whether `ok` is exactly `false`:

```aql
import "./decision.aql"
def table (Decision.make-table [
  (Decision.make-rule {field:"age" op:"gte" value:65} {category:"senior"})
])

def out (Decision.decide table {age:30})
print (if ((out.ok) false eq) ["no rule matched"] [out]) end   # => no rule matched

def out2 (Decision.decide table {age:70})
print (if ((out2.ok) false eq) ["no rule matched"] [out2]) end   # => {category: senior}
```

`(out.ok)` reads `false` on a miss and `None` on a hit, so
`(out.ok) false eq` is true exactly when the evaluation failed. The
`error` field then tells you why:

```aql
import "./decision.aql"
def table (Decision.make-table [
  (Decision.make-rule {field:"age" op:"gte" value:65} {category:"senior"})
])
def out (Decision.decide table {age:30})
print (out.error) end                       # => no-match
print (Decision.decide {kind:"graph"} {x:1}) end   # => {ok:false error:unknown-model-kind}
```

The full set of error strings: `"no-match"`, `"multiple-matches"`
(unique policy), `"unknown-model-kind"` (`decide` on a `kind` that is
neither `"table"` nor `"tree"`), and the tree-walk errors
`"no-branch-match"`, `"node-not-found"`, `"unknown-node-kind"`, and
`"max-depth-exceeded"`.

One failure mode **does** raise rather than return an error Map: an
ordering op (`lt/lte/gt/gte`) against a **missing** field, because the
missing value is `None` and `None` is not Comparable. Keep ordered
fields present (see [Use compound conditions](#use-compound-conditions)),
or trap the raise with `do … error …`:

```aql
import "./decision.aql"
def safe (do [(Decision.eval-cond {field:"score" op:"gte" value:50} {age:25})]
             error [var [[e] "field missing — treated as no match"]])
print (safe) end   # => field missing — treated as no match
```

---

## Use it from your own script

Import the library by relative path — it pulls in no `aql:*`
dependencies, so there is nothing else to import:

```aql
import "./decision.aql"

def table (Decision.make-table [
  (Decision.make-rule {field:"age" op:"lt"  value:13} {group:"child"})
  (Decision.make-rule {field:"age" op:"lt"  value:20} {group:"teen"})
  (Decision.make-rule {field:"age" op:"gte" value:20} {group:"adult"})
])

# classify a batch of inputs (push a sentinel 0 so the each body yields)
def people [{age:8} {age:16} {age:42}]
def _ (people each [
  var [[p]
    def out (Decision.decide table p)
    print `age ${(p.age)} -> ${(out.group)}` end
    0
  ]
])
```

Run it and you get one line per input:

```console
age 8 -> child
age 16 -> teen
age 42 -> adult
```

The canonical call form is forward — the verb first, then its arguments
(`Decision.decide table input`). **Wrap a call in parens, or end it,**
when a bare value would otherwise follow the verb and get swallowed:
`(Decision.decide table {age:25})`. The evaluators take the **model
first, the input second** — passing them the other way round is the most
common mistake. `test/decision_smoke_test.aql` is a complete worked
example you can copy from, and [AGENTS.md](../AGENTS.md) is the
condensed calling guide.

---

## Run the tests

Five suites ship with the module. Run them with `aql` from the repo root
(so `import "./decision.aql"` resolves):

```bash
aql test/decision_unit_test.aql   # example-based unit tests — direct (aql:test)
aql test/decision_unit_spec.aql   # example-based unit tests — declarative spec format
aql test/decision_prop_test.aql   # property tests — direct Test.check-prop form
aql test/decision_prop_spec.aql   # property tests — declarative spec format
aql test/decision_smoke_test.aql  # end-to-end walk-through over every public word
```

The file names follow a consistent convention: `_test.aql` is a direct
suite (assertions or `Test.check-prop` calls written out in code), and
`_spec.aql` is a declarative suite (cases or properties built as data
and handed to a runner). Both the unit and property layers ship in both
forms.

The two unit suites express the same example checks two ways:
`decision_unit_test.aql` asserts imperatively with `Test.test` /
`Assert.equal`, while `decision_unit_spec.aql` builds each check as a
`TestSpec` (`Test.spec` / `Test.case`) that `Test.run-spec` dispatches.

The two property suites are likewise split: `decision_prop_spec.aql`
builds each property as a declarative `PropertySpec` (`Test.prop`) and
runs it with `Test.run-property`, while `decision_prop_test.aql` calls
the imperative `Test.check-prop` driver directly, passing
`runs`/`seed`/`max-shrinks` explicitly.

Each assertion-bearing suite ends by asserting `Test.fail-count` is `0`,
so a failure makes `aql` exit non-zero — which is exactly what the
[CI workflow](../.github/workflows/test.yml) checks on every push and
pull request. The smoke suite carries no assertions; it passes by
running clean (exit `0` with no error).

## Run the suites under every execution mode

AQL can run a program three ways:

- **interpreter** — `aql script.aql`: the default tree-walking engine.
- **check** — `aql check script.aql`: the static type-checker (no
  execution); it exits non-zero if it reports any error.
- **bytecode** — `aql --force-compile script.aql`: compiles the program
  to a flat strict-stack form and runs it on the kernel VM. It *aborts*
  with a refusal reason when it can't lower a program faithfully (rather
  than silently falling back to the interpreter, which plain `--compile`
  does) — so a clean run is proof the VM actually executed the program.

`test/diverge.sh` is the gate, and it **tracks the latest `aql` from
`main`** — AQL is on an iterative-improvement track, so the gate targets
the newest build rather than pinning a fixed one. It runs every suite
under all three modes:

```bash
bash test/diverge.sh
# decision_unit_test.aql       interp ok  |  check ok      |  compile n/a (refused)
# decision_unit_spec.aql       interp ok  |  check ok      |  compile n/a (refused)
# decision_prop_test.aql       interp ok  |  check ok      |  compile ok (== interp)
# decision_prop_spec.aql       interp ok  |  check ok      |  compile n/a (refused)
# decision_smoke_test.aql      interp ok  |  check 16 err  |  compile n/a (refused)
# status: 4/5 suites check-clean; 1/5 suites compile (divergence-checked); the rest are upstream-pending.
# OK: interpreter passes every suite; no interpreter/bytecode divergence on any compiled suite
```

Two invariants are **hard** (a violation fails the gate):

1. the interpreter passes every suite (the supported path);
2. every suite the compiler **accepts** produces output byte-identical to
   the interpreter — the two engines never diverge.

Everything else is **current status**, reported per suite because it moves
as `aql` improves and is outside this repo's control: the per-suite
`check` error counts (the checker still can't trace some namespace-exposed
/ dynamically-dispatched words — false positives the interpreter runs
green), and which suites the compiler accepts (the test-framework
code-body words `test-test` / `each` are still being lowered upstream).
The compilable subset is **auto-detected**, so as more suites start
compiling they are divergence-checked automatically — no edit needed.

Resolving the build (latest `main` by default): the gate uses
`$BYTECODE_AQL` if you point it at a binary, otherwise it builds
`$BYTECODE_AQL_REF` (default: current `main` HEAD), caching by sha in
`~/.local/bin`. The project's pinned `AQL_REF` (`958c379b`) predates the
bytecode compiler and is **only** the interpreter baseline — the gate's
build is independent of it. Because the proxy git relay is scoped, the
source is fetched as an HTTPS tarball from codeload; a new sha needs `go`
+ network, after which it's cached. To pin a specific commit (e.g. for a
reproducible CI run), pass `BYTECODE_AQL_REF=<sha>`. To wire the gate into
CI, add a step that runs `bash test/diverge.sh` after the suites; note
that editing `.github/workflows/` needs a token with `workflow` scope.
