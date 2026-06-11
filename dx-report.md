# Developer-experience report: decision on AQL

**Date:** 2026-06-11
**AQL build under test:** `aql-lang/aql` @ `958c379b` (the binary reports its
version string as `aql 958c379b`).
**Context:** building and testing this `Decision` library — a pure-AQL port
of the interpreter's internal `aql:decision` module (conditions, predicates,
decision tables, decision trees). Everything below was reproduced first-hand
against the build above; each item carries a minimal repro you can paste into
a `.aql` file (alongside `decision.aql`) and run with
`/path/to/aql script.aql`.

Severity: **🔴 high** (silent wrong results / blocks a use case) ·
**🟡 medium** (friction, clear workaround) · **🟢 low** (papercut).

---

## Why this module pins a *newer* aql than the template

The bloom-filter template builds against `db828ec`. This library does **not**
build there — it pins **`958c379b`** (a descendant of `db828ec`) because it
leans on language surface the older commit lacks:

- `surface` + `exposes` — `Comparable` is declared as a *surface*
  (`def Comparable surface {cmp: (fnsig [[Self Self] [Integer]])}`) and the
  scalar builtins join it with `Integer exposes Comparable`, etc. The
  ordering operators are written against that contract, not against concrete
  types.
- `gen [R]` generics on the records — `Rule`/`LeafNode` are generic in their
  result type; `DTable`/`DTree` carry a *defaulted* `R` so bare construction
  still works (their fields hold rule/node *lists*, which give no direct
  evidence for inference).
- `refine Record` for the record types, and `fnsig` for the surface contract.

It imports **no `aql:*` dependencies** — the only `import` is the relative
`import "./decision.aql"`. So the migration story that dominates the
bloom-filter report (util-module renames, PascalCase namespaces, the
`import "x" end` terminator) is mostly moot here: there is one import and it
needs no terminator because nothing follows it on the line. The real cost of
the newer pin is just that: you must build aql at `958c379b`, not reuse a
`db828ec` checkout.

---

## The genuinely non-obvious things

### 1. 🟡 Evaluators take the **model first**, the input second

Every evaluator reads as `Decision.verb model input`:

```aql
import "./decision.aql"
def table (Decision.make-table [
  (Decision.make-rule {field:"age" op:"lt"  value:18} {category:"minor"})
  (Decision.make-rule {field:"age" op:"gte" value:65} {category:"senior"})
])
(Decision.decide table {age:12}) print end   # => {category: minor}
```

This is the opposite of the "data first" grain you might expect from a
data-flow language — the *input* is the data, yet the *model* leads. In stack
form the model sits on **top** of the input (`input table Decision.eval-table`).
`apply-op` is the same way but with a twist: it is written
`Decision.apply-op rhs op lhs` and computes `lhs op rhs`, so
`Decision.apply-op 18 "gte" 25` is `25 gte 18` → `true`. Get the order wrong
and you don't get an error, you get a *quietly inverted* answer
(`apply-op 25 "gte" 18` → `false`). Verified.

### 2. 🔴 An ordering op on a **missing field** raises `not_comparable` — by design

A missing field reads as `None`, which is **not** `Comparable`. So an ordering
condition over a field the input lacks does not return `false` — it *raises*:

```aql
import "./decision.aql"
(Decision.eval-cond {field:"age" op:"gte" value:18} {name:"x"}) print end
# error: CallAQL: [aql/not_comparable]: gte
```

This is deliberate, and it is the most important behaviour to internalise. The
relational form of `apply-op` is `gen [(T extends Comparable)]`; when a
`None` operand fails that bound it falls through to the `Any` overload, which
implements only `eq`/`neq` and **raises `not_comparable`** on any ordering op.
The design choice is *loud over silently-false*: a rule that compares a field
that isn't there is almost always a bug in the model or the input, and the
library refuses to paper over it. The practical consequence: keep the field
present, or gate it with an equality check, before you compare it with
`lt`/`lte`/`gt`/`gte`. (Verified: the same input with `op:"eq"` returns
`false` cleanly — equality tolerates a missing field; ordering does not.)

### 3. 🟡 The unary `is_*` ops are **unreachable through `eval-cond`**

`apply-op` has two arities: a two-operand **unary** form that handles
`is_true`/`is_false`/`is_null`/`is_not_null`, and a three-operand **binary**
form for `eq`/`neq`/`lt`/`lte`/`gt`/`gte`. `eval-cond` is hard-wired to call
the *binary* form — it always supplies three operands
(`input.field`, `op`, `value`). So a condition whose `op` is one of the unary
set never reaches the code that understands it:

```aql
import "./decision.aql"
(Decision.eval-cond {field:"age" op:"is_null" value:0} {age:5}) print end
# error: CallAQL: [aql/unknown_op]: is_null
```

The unary ops *do* work — but only by calling `apply-op` directly with two
operands:

```aql
(Decision.apply-op true "is_true")     print end   # => true
(Decision.apply-op 5    "is_not_null") print end   # => true
```

Two gotchas compound here. First, because `eval-cond` routes through the
binary form, `is_*` inside a `cond`/`rule`/`tree` condition is effectively a
runtime error, not a usable operator — reach for `eq`/`neq` against an
explicit `value` instead. Second, even the direct unary form is *structural,
not value-sensing*: `is_null` always returns `false` and `is_not_null` always
returns `true` regardless of the operand (`Decision.apply-op None "is_null"`
→ `false`). They assert "this operand exists" by virtue of having been passed
at all. Verified.

### 4. 🟡 `make-rule` demands a `Map` `then`; `make-leaf` accepts **any** result

The two "terminal result" builders are asymmetric, and the asymmetry is a
signature constraint, not a convention:

```aql
import "./decision.aql"
def w {field:"age" op:"gte" value:18}
(Decision.make-rule w "adult") print end
# error: [aql/uncalled_function]: call to 'make-rule' matched no signature …
(Decision.make-leaf leaf/q "too-young") print end   # => {id: leaf, kind: leaf, result: too-young}
(Decision.make-leaf leaf/q 42)          print end   # => {id: leaf, kind: leaf, result: 42}
```

`make-rule`'s signature is `[when:Map then:Map]`, so a table rule's payload
**must be a Map** — a scalar `then` is rejected as "matched no signature".
`make-leaf` is `[id:Atom result:Any]`, so a tree leaf can carry any value
(String, Integer, Map). If you want a table that routes to a bare string,
either wrap it (`{result:"adult"}`) or write the rule as a Map literal — the
evaluators only read fields and don't enforce `then:Map` at eval time, the
*builder* does. Verified.

### 5. 🟢 Records are `refine Record`, so a model is just a `Map` literal

Every record type (`Cond`, `Pred`, `Rule`, `DTable`, `DTree`,
`BranchNode`, `LeafNode`) is a `refine Record`, and the evaluators read fields
by name. That means **you never have to call a builder** — a whole table or
tree can be a plain Map literal and evaluate identically:

```aql
import "./decision.aql"
def tbl {kind:"table" hit-policy:"first" rules:[
  {when:{field:"age" op:"lt"  value:18} then:{category:"minor"}}
  {when:{field:"age" op:"gte" value:18} then:{category:"adult"}}
]}
(Decision.decide tbl {age:25}) print end   # => {category: adult}
```

This is a genuine convenience (models load straight from JSON-shaped data),
but it interacts with §4 and §6: the Map-literal path **skips the builders'
type checks**, so a `then:` that a builder would reject sails through, and an
id that a builder requires as an `Atom` is written as a plain `String` in the
literal. Which leads to —

### 6. 🟢 Builder ids are `Atom`s (`/q`), but Map-literal ids are `String`s

`make-branch`/`make-leaf`/`make-tree` declare `id`/`root` as `Atom`, so a bare
name must be quoted: `Decision.make-branch root/q […]`. Pass a String and the
builder rejects it (`matched no signature`). Yet the canonical *Map-literal*
tree uses **String** ids throughout — `{id:"root" …}`, `root:"root"` — and
works, because the tree walker compares ids with `convert String` on both
sides. So the same field is an `Atom` when you build it and a `String` when
you hand-write it. Pick one style per model and don't mix; both are verified
to evaluate correctly.

### 7. 🟢 A "miss" is a **value**, not a throw — check `.ok` / `.error`

Evaluators never throw on a non-match. They **return** a Map
`{ok:false error:"…"}`:

```aql
import "./decision.aql"
(Decision.decide table {age:30})         print end   # => {ok: false, error: no-match}
(Decision.decide {kind:"frob"} {x:1})    print end   # => {ok: false, error: unknown-model-kind}
```

The full set observed: `no-match`, `multiple-matches` (a `"unique"` table
with >1 match), `unknown-model-kind`, `no-branch-match`, `node-not-found`,
`unknown-node-kind`, `max-depth-exceeded`. The contrast with §2 is the thing
to hold in your head: a **structural** miss (no rule fired, no branch matched,
unknown kind) is a *returned* error value you branch on; a **type** violation
(comparing a `None`/non-`Comparable` operand with an ordering op) is a
*raised* error you must prevent. Two different failure channels for two
different kinds of mistake. The `collect` policy is the one evaluator that
returns a plain `List` (of every matching `then`) rather than a single
result or an error. Verified.

### 8. 🟢 `print` forward-arg collection still reverses chained prints

Unchanged from the language generally, but it bit repeatedly while probing
this module, where you naturally want to print several `decide` results in a
row. `print` collects a forward argument, so `(a) print (b) print` can
reorder, and a trailing `print` at end-of-input may not find its argument.
Write one value per statement: `print (value) end` or `(value) print end`.

---

## What worked well

- **Static dispatch carries real semantics here.** The `Comparable` surface
  plus the two-overload `apply-op` means "is this operand comparable?" is
  answered by the type system, not by a runtime `if`. The `not_comparable`
  raise in §2 is that design paying off — loud, located
  (`[aql/not_comparable]: gte`), and impossible to ignore.
- **Defaulted generics make the dual builder/literal surface painless.**
  `DTable`/`DTree` defaulting `R` to `Any` is exactly what lets §5 work —
  bare Map-literal models construct without the user ever naming a result
  type.
- **Error spans point at the real call.** The `uncalled_function` hint in §4
  even suggests the `/r` reference form, and the `signature_error` message
  flags the "forward args may have run into the next word — group with
  parens" case, which is the most common authoring slip with these
  multi-arg verbs.

---

## Summary

| # | Severity | Issue |
|---|----------|-------|
| 1 | 🟡 | Evaluators are **model-first**; `apply-op` is `rhs op lhs` (computes `lhs op rhs`) — wrong order silently inverts |
| 2 | 🔴 | Ordering op on a **missing field** raises `not_comparable` (None ∉ Comparable) — loud by design, not silent-false |
| 3 | 🟡 | Unary `is_*` ops are **unreachable via `eval-cond`** (it calls binary `apply-op`); the direct form is value-blind |
| 4 | 🟡 | `make-rule` requires `then:Map`; `make-leaf` takes `result:Any` — asymmetric builder constraints |
| 5 | 🟢 | Records are `refine Record`, so models double as plain Map literals (skipping builder checks) |
| 6 | 🟢 | Builder ids are `Atom` (`/q`); Map-literal ids are `String` — same field, two types |
| 7 | 🟢 | A miss is a returned `{ok:false error:…}` value, not a throw — a distinct channel from §2's raise |
| 8 | 🟢 | `print` forward-collection reverses chained prints — one value per statement |
