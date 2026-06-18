---
name: decision-aql
description: Use when writing or editing AQL code that calls the Decision decision-logic library — Decision.cond / all-of / any-of / not-of / make-rule / make-table / with-policy / make-branch / make-leaf / make-tree / eval-cond / eval-pred / eval-table / eval-tree / decide / apply-op, or any file that does `import "./decision.aql"`. Provides the exact AQL calling convention (which is not C/Python/JS), the model-first evaluator arg order, the builders/evaluators/ops/hit-policies, verified copy-paste idioms (a table and a tree), and fixes for the mistakes agents most often make (foreign call syntax, swapped model/input order, the missing-field `not_comparable` raise).
---

# Calling the Decision decision-logic library (AQL)

Declarative **decision logic**: express business rules as data — a
**condition**, a compound **predicate**, a **decision table** (rules + hit
policy), or a **decision tree** (branch/leaf nodes) — then evaluate against an
input `Map`. Public surface = the `Decision` namespace. Everything below is
verified against `aql @ 958c379b` (pinned) and `aql @ 5aed3834` (latest main).

## Import

```aql
import "./decision.aql"
```

- Path resolves relative to the **working directory the script runs from**,
  not the importing file. Run scripts from where that relative path is valid.
- Needs **aql ≥ `958c379b`** (surface/exposes, generics, `refine Record`,
  `fnsig`). It imports no `aql:*` dependencies.

## The one calling rule

AQL has no `f(a, b)` and no `obj.method(a)`. The canonical form is **forward**
— the verb first, then its arguments:

```
Decision.verb arg1 arg2
```

- **Evaluators take the MODEL first, the input second:**
  `Decision.eval-table table input`, `Decision.decide model input`,
  `Decision.eval-cond cond input`. (In stack form the model sits on *top*:
  `input table Decision.eval-table`.)
- **Wrap a call in parens, or end it,** when a bare value would otherwise
  follow the verb and get swallowed: `(Decision.decide table {age:25})`.

## API

Records are plain `refine Record` values — build them with a builder **or**
write them as Map literals; the evaluators only read fields.

**Builders**

| Call | Returns | Notes |
|------|---------|-------|
| `Decision.cond field op value` | `Cond` | `field` is an Atom (`age/q`); `op` a String. |
| `Decision.all-of children` | `Pred` | every child must hold. |
| `Decision.any-of children` | `Pred` | at least one child must hold. |
| `Decision.not-of child` | `Pred` | negate one condition. |
| `Decision.make-rule when then` | `Rule` | `then` MUST be a Map. |
| `Decision.make-table rules` | `DTable` | list of rules; hit policy defaults to `"first"`. |
| `Decision.with-policy policy table` | `DTable` | copy `table` with a new hit policy. |
| `Decision.make-branch id branches` | `BranchNode` | `id` Atom; `branches` = `[{when:… next:…} …]`. |
| `Decision.make-leaf id result` | `LeafNode` | `id` Atom; `result` any value. |
| `Decision.make-tree root nodes` | `DTree` | `root` = start node id (Atom); `nodes` = node list. |

**Evaluators** (each applied against an input `Map`)

| Call | Returns | Notes |
|------|---------|-------|
| `Decision.apply-op rhs op lhs` | `Boolean` | primitive compare: `lhs op rhs`. |
| `Decision.eval-cond cond input` | `Boolean` | reads `input.(cond.field)`, applies `cond.op` vs `cond.value`. |
| `Decision.eval-pred pred input` | `Boolean` | evaluates an all/any/not group (or a bare cond). |
| `Decision.eval-table table input` | result, or `{ok:false error:…}` | runs the table under its hit policy. |
| `Decision.eval-tree tree input` | leaf result, or `{ok:false error:…}` | walks branches to a leaf. |
| `Decision.decide model input` | as above | dispatches on `model.kind` (`"table"` / `"tree"`). |

**Operators** (the `op` String) — binary, Comparable: `eq` `neq` `lt` `lte`
`gt` `gte` (used in conditions and `apply-op`); unary: `is_true` `is_false`
`is_null` `is_not_null` — reachable **only** via the direct two-arg
`Decision.apply-op rhs op`, **not** inside a condition/table/tree (eval-cond
always supplies a `value`, so a unary op there raises).

**Hit policies** (tables) — `"first"` *(default)* first match's `then`;
`"unique"` the single match (`{ok:false error:"multiple-matches"}` if >1);
`"collect"` a **List** of every match's `then`; `"priority"` the match with the
highest `priority` field (default `0`).

**Error results** — evaluators never throw on a miss; they return a Map
`{ok:false error:…}`: `"no-match"`, `"multiple-matches"`,
`"unknown-model-kind"`, `"no-branch-match"`, `"node-not-found"`,
`"unknown-node-kind"`, `"max-depth-exceeded"`.

## Idioms (verified)

A decision **table** (first-match routing):

```aql
import "./decision.aql"
def rules [
  (Decision.make-rule {field:"age" op:"lt"  value:18} {category:"minor"})
  (Decision.make-rule {field:"age" op:"gte" value:65} {category:"senior"})
]
def table (Decision.make-table rules)
(Decision.decide table {age:12}) print   # => {category: minor}
(Decision.decide table {age:70}) print   # => {category: senior}
(Decision.decide table {age:30}) print   # => {ok:false error:no-match}
```

Collect every matching rule instead of just the first:

```aql
def tags (Decision.with-policy "collect" (Decision.make-table [
  (Decision.make-rule {field:"age"   op:"gte" value:18} {tag:"adult"})
  (Decision.make-rule {field:"score" op:"gte" value:50} {tag:"passing"})
]))
(Decision.decide tags {age:25 score:80}) print   # => [{tag: adult}, {tag: passing}]
```

A decision **tree** (branch → leaf):

```aql
def tree {kind:"tree" root:"root" nodes:[
  {id:"root" kind:"branch" branches:[
    {when:{field:"age" op:"lt"  value:18} next:"minor"}
    {when:{field:"age" op:"gte" value:18} next:"adult"}
  ]}
  {id:"minor" kind:"leaf" result:"too-young"}
  {id:"adult" kind:"leaf" result:"welcome"}
]}
(Decision.decide tree {age:40}) print   # => welcome
```

## Common mistakes

| ✗ Don't write | ✓ Write | Why |
|---------------|---------|-----|
| `Decision.decide {age:25} table` | `Decision.decide table {age:25}` | The **model comes first**, the input second. |
| `decide table input` (unqualified) | `Decision.decide table input` | Words live under the `Decision` namespace after import. |
| `Decision.eval-table rules input` | `Decision.eval-table table input` | Pass the **table** (`make-table rules`), not the raw rules list. |
| `op: ">="` / `op: "ge"` | `op: "gte"` | Condition ops are `eq/neq/lt/lte/gt/gte`; the unary `is_*` set works only via direct `apply-op`. |
| compare a Map/List with `lt` | compare scalars (or `eq`/`neq` only) | Ordering ops need **Comparable** operands; else `apply-op` raises `not_comparable`. |
| treat a miss as an exception | inspect `result.error` (a hit has none) | A *non-match* returns `{ok:false error:"…"}` (no throw); a hit is your bare `then`/leaf value. |
| an ordering op (`lt`/`gte`/…) on a maybe-missing field | guarantee the field is present, or compare with `eq`/`neq` only | A missing field is `None`, not Comparable, so an ordering op **raises** `not_comparable`. (`is_*` can't gate this — not usable in conditions.) |
| `make-branch "root" …` | `make-branch root/q …` | The builder's `id` is an **Atom**; quote bare names with `/q`. |

A note on `print` while debugging: `print` collects a forward argument, so a
chain like `(a) print (b) print` can reorder. Write `print (value) end` (or
`(value) print end`), one value per statement.

If the full repo is available, `AGENTS.md`, `api.json` (machine-readable
signatures), and `docs/reference.md` have the complete guide;
`test/decision_smoke_test.aql` is a runnable example.
