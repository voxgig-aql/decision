# Reference

Technical description of the `decision` module's public surface.
This page is information-oriented: it states what each word is, its
call shape, and what it returns. For *why* the model behaves the way
it does, see [Explanation](explanation.md); for goal-directed recipes,
see the [How-to guides](how-to.md). For a hands-on first run, start
with the [Tutorial](tutorial.md).

> **AI agents:** [AGENTS.md](../AGENTS.md) condenses the calling
> convention, idioms, and common mistakes for machine use.

The module exports a single namespace, `Decision`, plus its record
types and the `Comparable` surface. Import it with:

```aql
import "./decision.aql"
```

The path resolves **relative to the working directory the script is run
from**, not the importing file — run scripts from the directory where
`./decision.aql` is valid. The library imports no `aql:*` dependencies,
so a consumer needs nothing else; it does require **aql ≥ `958c379b`**
(it uses `surface`/`exposes`, generics, `refine Record`, and `fnsig`).

---

## Calling convention

The canonical call form is **forward** — the verb first, then its
arguments: `Decision.verb arg1 arg2`. There is no `f(a, b)` and no
`obj.method(a)`; words live under the `Decision` namespace after import.

Two ordering facts:

- **The receiver (model/input) comes last** — model first, input second:
  `Decision.eval-table table input`, `Decision.decide model input`,
  `Decision.eval-cond cond input`. A piping form also binds
  (`input Decision.decide model`), but putting the receiver **first**
  silently misbinds — both are `Map`s, so nothing type-checks it and you
  get a plausible-looking wrong result, not an error.
- **`apply-op` reads as `lhs op rhs`** but is *written*
  `Decision.apply-op rhs op lhs` — the right operand first, then the
  op, then the left operand (it computes `lhs op rhs`).

**Wrap a call in parens, or end it,** when a bare value would otherwise
follow the verb and get swallowed: `(Decision.decide table {age:25})`.
A note on `print` while debugging: `print` collects a forward argument,
so write one value per statement — `print (value) end` or
`(value) print end`.

Records are plain `refine Record` values: build them with a builder
**or** write them as Map literals; the evaluators only read fields.

---

## Types

Each type below is an exported `refine Record` (some generic in a
result type `R`). Evaluating the bare name yields its record shape; the
builders construct instances, but a hand-written Map with the same
fields works identically.

### `Cond`

`refine Record [field:Atom op:String value:Any]` — a single
field/op/value condition. `field` is the input key to read, `op` is one
of the [operators](#operators) below, `value` is the right operand
(omitted for the unary ops).

### `Pred`

`refine Record [kind:String op:String children:Any]` — a compound
predicate. Built by `all-of`/`any-of`/`not-of`; `kind` is always
`"group"`, `op` is `"all"`, `"any"`, or `"not"`, and `children` is the
list of sub-conditions (a single condition Map for `"not"`).

### `Rule`

`gen [R] refine Record [when:Map then:R]` — a `when → then` pairing,
generic in its result type `R`. `when` is a condition or predicate Map;
`then` is the result yielded when `when` holds. Bare, it reads as
`schema<Record/Rule>[R]`; instantiated, `Rule of [Map]` recovers the
concrete `record{when:Map then:Map}`.

### `DTable`

`gen [(R default Any)] refine Record [kind:String rules:List hit-policy:String]`
— a decision table, generic in `R` (defaulted to `Any`, because a rule
*list* gives no direct evidence of the result type). `kind` is
`"table"`, `rules` is a List of `Rule` records, `hit-policy` is one of
the [hit policies](#hit-policies). Bare it reads as
`schema<Record/DTable>[R]`; `DTable of []` fully defaults to
`record{kind:String rules:List hit-policy:String}`.

### `DTree`

`gen [(R default Any)] refine Record [kind:String root:Atom nodes:List]`
— a decision tree, generic in `R` (defaulted like `DTable`). `kind` is
`"tree"`, `root` is the start node id (an Atom), `nodes` is the List of
`BranchNode`/`LeafNode` records.

### `BranchNode`

`refine Record [id:Atom kind:String branches:List]` — an interior tree
node. `id` is the node id (Atom), `kind` is `"branch"`, `branches` is a
List of `{when:… next:…}` maps: each `when` is a condition/predicate and
`next` names the node to walk to when it holds.

### `LeafNode`

`gen [R] refine Record [id:Atom kind:String result:R]` — a terminal
tree node, generic in its result type `R`. `id` is the node id (Atom),
`kind` is `"leaf"`, `result` is the value returned when the walk reaches
this node. Instantiated, `LeafNode of [Integer]` pins the result field
to `record{id:Atom kind:String result:Integer}`.

### `Comparable`

`surface {cmp: (fnsig [[Self Self] [Integer]])}` — the **surface** (the
`cmp` contract) that the ordering operators (`lt`/`lte`/`gt`/`gte`)
require. It is exposed by the scalar builtins `Integer`, `Float`,
`String`, `Boolean`, and `Atom`; a user type joins by exposing
`Comparable` itself. It is a membership test, not a record:

```aql
(5 is Decision.Comparable) print     # => true   (a scalar is Comparable)
({a:1} is Decision.Comparable) print # => false  (a map has no cmp contract)
```

---

## Words

Builders construct records; evaluators apply a model/condition against
an input `Map`. The `Call` row shows the natural left-to-right forward
form.

### `Decision.cond`

Construct a single condition.

| | |
|--|--|
| **Call**    | `Decision.cond field op value` |
| **Args**    | `field` (Atom — quote with `/q`), `op` (String), `value` (Any) |
| **Returns** | `Cond` |

```aql
(Decision.cond age/q "gte" 18) print
# => {field: age, op: gte, value: 18}
```

### `Decision.all-of`

Build an *every-child-must-hold* predicate.

| | |
|--|--|
| **Call**    | `Decision.all-of children` |
| **Args**    | `children` (List of condition/predicate Maps) |
| **Returns** | `Pred` (`kind:"group" op:"all"`) |

```aql
(Decision.all-of [{field:"age" op:"gte" value:18} {field:"score" op:"gt" value:50}]) print
# => {kind: group, op: all, children: [{field: age, op: gte, value: 18}, {field: score, op: gt, value: 50}]}
```

### `Decision.any-of`

Build an *at-least-one-child-must-hold* predicate.

| | |
|--|--|
| **Call**    | `Decision.any-of children` |
| **Args**    | `children` (List of condition/predicate Maps) |
| **Returns** | `Pred` (`kind:"group" op:"any"`) |

### `Decision.not-of`

Negate a single condition.

| | |
|--|--|
| **Call**    | `Decision.not-of child` |
| **Args**    | `child` (a single condition Map) |
| **Returns** | `Pred` (`kind:"group" op:"not"`) |

```aql
(Decision.not-of {field:"age" op:"lt" value:18}) print
# => {kind: group, op: not, children: {field: age, op: lt, value: 18}}
```

### `Decision.make-rule`

Pair a `when` condition/predicate with a `then` result.

| | |
|--|--|
| **Call**    | `Decision.make-rule when then` |
| **Args**    | `when` (condition/predicate Map), `then` (a Map result) |
| **Returns** | `Rule` |

```aql
(Decision.make-rule {field:"age" op:"gte" value:18} {category:"adult"}) print
# => {when: {field: age, op: gte, value: 18}, then: {category: adult}}
```

`then` MUST be a Map.

### `Decision.make-table`

Assemble a list of rules into a table.

| | |
|--|--|
| **Call**    | `Decision.make-table rules` |
| **Args**    | `rules` (List of `Rule` records / `{when:… then:…}` maps) |
| **Returns** | `DTable` (hit policy defaults to `"first"`) |

```aql
(Decision.make-table [{when:{field:"age" op:"lt" value:18} then:{category:"minor"}}]) print
# => {kind: table, rules: [{then: {category: minor}, when: {field: age, op: lt, value: 18}}], hit-policy: first}
```

### `Decision.with-policy`

Copy a table with a new hit policy.

| | |
|--|--|
| **Call**    | `Decision.with-policy policy table` |
| **Args**    | `policy` (String — one of the [hit policies](#hit-policies)), `table` (`DTable`) |
| **Returns** | `DTable` (same rules, swapped `hit-policy`) |

```aql
def t (Decision.make-table [{when:{field:"x" op:"gt" value:0} then:{s:"pos"}}])
(Decision.with-policy "unique" t) print
# => {kind: table, rules: [{then: {s: pos}, when: {field: x, op: gt, value: 0}}], hit-policy: unique}
```

### `Decision.make-branch`

Build an interior tree node.

| | |
|--|--|
| **Call**    | `Decision.make-branch id branches` |
| **Args**    | `id` (Atom — quote with `/q`), `branches` (List of `{when:… next:…}`) |
| **Returns** | `BranchNode` (`kind:"branch"`) |

```aql
(Decision.make-branch root/q [{when:{field:"age" op:"gte" value:18} next:"adult"}]) print
# => {id: root, kind: branch, branches: [{next: adult, when: {field: age, op: gte, value: 18}}]}
```

### `Decision.make-leaf`

Build a terminal tree node.

| | |
|--|--|
| **Call**    | `Decision.make-leaf id result` |
| **Args**    | `id` (Atom — quote with `/q`), `result` (Any) |
| **Returns** | `LeafNode` (`kind:"leaf"`) |

```aql
(Decision.make-leaf adult/q {category:"adult"}) print
# => {id: adult, kind: leaf, result: {category: adult}}
```

### `Decision.make-tree`

Assemble a root id and node list into a tree.

| | |
|--|--|
| **Call**    | `Decision.make-tree root nodes` |
| **Args**    | `root` (Atom — quote with `/q`), `nodes` (List of branch/leaf nodes) |
| **Returns** | `DTree` (`kind:"tree"`) |

```aql
(Decision.make-tree root/q [{id:"root" kind:"leaf" result:"x"}]) print
# => {kind: tree, root: root, nodes: [{id: root, kind: leaf, result: x}]}
```

### `Decision.apply-op`

The primitive comparison applied by `eval-cond`. Written
**right-operand-first**; it computes `lhs op rhs`.

| | |
|--|--|
| **Call**    | `Decision.apply-op rhs op lhs` (binary) — or `Decision.apply-op rhs op` (unary) |
| **Args**    | `rhs` (Any), `op` (String), `lhs` (Any) |
| **Returns** | `Boolean` |

The binary form is generic over `Comparable`: the ordering ops
(`lt`/`lte`/`gt`/`gte`) require both operands in the surface, while
`eq`/`neq` are defined for everything. The 2-arg form handles the
unary ops (`is_true`/`is_false`/`is_null`/`is_not_null`).

```aql
(Decision.apply-op 18 "gte" 25) print   # => true   (lhs 25 gte rhs 18)
(Decision.apply-op 25 "gte" 18) print   # => false  (lhs 18 gte rhs 25)
(Decision.apply-op "a" "lt" "b") print  # => false  (Strings Comparable: lhs 'b' lt rhs 'a')
(Decision.apply-op 5 "is_not_null") print # => true (unary, 2-arg form)
```

An ordering op on a non-Comparable operand raises (see
[Errors](#errors-at-a-glance)); an unrecognised op raises `unknown_op`.

### `Decision.eval-cond`

Test one condition against an input map. Reads `input.(cond.field)` and
applies `cond.op` against `cond.value`.

| | |
|--|--|
| **Call**    | `Decision.eval-cond cond input` |
| **Args**    | `cond` (`Cond` Map), `input` (Map) |
| **Returns** | `Boolean` |

```aql
(Decision.eval-cond {field:"age" op:"gte" value:18} {age:25}) print  # => true
(Decision.eval-cond {field:"age" op:"gte" value:18} {age:15}) print  # => false
```

`eval-cond` always supplies three operands to `apply-op` (`rhs`, `op`,
`value`), so it dispatches the **binary** form. The unary ops
(`is_true`/`is_null`/…) therefore raise `not_comparable` *through*
`eval-cond` — use `apply-op rhs op` directly for those.

### `Decision.eval-pred`

Evaluate a compound predicate (an `all`/`any`/`not` group, or a bare
condition).

| | |
|--|--|
| **Call**    | `Decision.eval-pred pred input` |
| **Args**    | `pred` (`Pred` Map, or a bare `Cond` Map), `input` (Map) |
| **Returns** | `Boolean` |

```aql
def p (Decision.all-of [{field:"age" op:"gte" value:18} {field:"score" op:"gt" value:50}])
(Decision.eval-pred p {age:25 score:80}) print   # => true
```

### `Decision.eval-table`

Run a table under its hit policy.

| | |
|--|--|
| **Call**    | `Decision.eval-table table input` |
| **Args**    | `table` (`DTable`), `input` (Map) |
| **Returns** | the matching rule's `then` result — or, for `"collect"`, a List — or an error Map |

```aql
def tbl (Decision.make-table [
  {when:{field:"age" op:"lt"  value:18} then:{category:"minor"}}
  {when:{field:"age" op:"gte" value:18} then:{category:"adult"}}
])
(Decision.eval-table tbl {age:25}) print   # => {category: adult}
```

Pass the **table** (`make-table rules`), not the raw rules list. The
hit policy is read from the table's `hit-policy` field; see
[Hit policies](#hit-policies).

### `Decision.eval-tree`

Walk a tree's branches from its root to a leaf.

| | |
|--|--|
| **Call**    | `Decision.eval-tree tree input` |
| **Args**    | `tree` (`DTree`), `input` (Map) |
| **Returns** | the reached leaf's `result` — or an error Map |

```aql
def tree {kind:"tree" root:"root" nodes:[
  {id:"root" kind:"branch" branches:[
    {when:{field:"age" op:"lt"  value:18} next:"minor"}
    {when:{field:"age" op:"gte" value:18} next:"adult"}
  ]}
  {id:"minor" kind:"leaf" result:"too-young"}
  {id:"adult" kind:"leaf" result:"welcome"}
]}
(Decision.eval-tree tree {age:25}) print   # => welcome
```

The walk is capped at 100 hops (see [Complexity](#complexity)); a branch
where no `when` matches yields `{ok:false error:"no-branch-match"}`.

### `Decision.decide`

Dispatch on `model.kind` — `"table"` runs `eval-table`, `"tree"` runs
`eval-tree`. The top-level entry point.

| | |
|--|--|
| **Call**    | `Decision.decide model input` |
| **Args**    | `model` (a `DTable` or `DTree`), `input` (Map) |
| **Returns** | as `eval-table` / `eval-tree` — or `{ok:false error:"unknown-model-kind"}` |

```aql
def model {kind:"table" hit-policy:"first" rules:[
  {when:{field:"x" op:"gt" value:0} then:{sign:"positive"}}
]}
(Decision.decide model {x:5}) print   # => {sign: positive}
```

---

## Operators

The `op` String in a `Cond` / `apply-op` call.

| Op | Arity | Holds when |
|----|-------|-----------|
| `eq`  | binary | `lhs` equals `value` |
| `neq` | binary | `lhs` differs from `value` |
| `lt`  | binary | `lhs < value` (Comparable) |
| `lte` | binary | `lhs <= value` (Comparable) |
| `gt`  | binary | `lhs > value` (Comparable) |
| `gte` | binary | `lhs >= value` (Comparable) |
| `is_true`     | unary | `lhs` is truthy |
| `is_false`    | unary | `lhs` is falsy |
| `is_null`     | unary | `lhs` is null |
| `is_not_null` | unary | `lhs` is non-null |

The ordering ops (`lt`/`lte`/`gt`/`gte`) need **Comparable** operands
(scalars). `eq`/`neq` work for any value. The unary ops take no `value`
and reach `apply-op` only through the 2-arg form (not `eval-cond`).

## Hit policies

The `hit-policy` String in a `DTable` (set the default at `make-table`,
override with `with-policy`).

| Policy | Result |
|--------|--------|
| `"first"` *(default)* | the first matching rule's `then` |
| `"unique"` | the single match; `{ok:false error:"multiple-matches"}` if more than one matches, `{ok:false error:"no-match"}` if none |
| `"collect"` | a **List** of every matching rule's `then` (empty `[]` if none) |
| `"priority"` | the matching rule with the highest `priority` field (default `0`) |

```aql
def tags (Decision.with-policy "collect" (Decision.make-table [
  (Decision.make-rule {field:"age"   op:"gte" value:18} {tag:"adult"})
  (Decision.make-rule {field:"score" op:"gte" value:50} {tag:"passing"})
]))
(Decision.decide tags {age:25 score:80}) print   # => [{tag: adult}, {tag: passing}]
```

---

## Errors at a glance

Evaluators **never throw on a miss** — they return an error Map of the
shape `{ok:false error:"…"}`. Check `result.ok` / `result.error`; do not
treat a non-match as an exception. `apply-op`, by contrast, *raises* a
catchable error on a bad operand or op.

| Situation | Result |
|-----------|--------|
| table / tree finds no match (e.g. `first`, `unique`-with-none) | returns `{ok:false error:"no-match"}` |
| `"unique"` policy with more than one matching rule | returns `{ok:false error:"multiple-matches"}` |
| `decide` with a `model.kind` that is neither `"table"` nor `"tree"` | returns `{ok:false error:"unknown-model-kind"}` |
| a tree branch where no `when` holds | returns `{ok:false error:"no-branch-match"}` |
| a `next` id (or `root`) that names no node | returns `{ok:false error:"node-not-found"}` |
| a tree node whose `kind` is neither `"branch"` nor `"leaf"` | returns `{ok:false error:"unknown-node-kind"}` |
| a tree walk exceeding 100 hops (a cycle) | returns `{ok:false error:"max-depth-exceeded"}` |
| an **ordering op** (`lt`/`lte`/`gt`/`gte`) on a non-Comparable operand — a Map/List, or a **missing field** (`None`) | **raises** `[aql/not_comparable]` |
| `apply-op` with an unrecognised op String | **raises** `[aql/unknown_op]` |

A missing input field reads as `None`, which is not Comparable — so an
ordering op on a maybe-missing field raises `not_comparable` rather than
returning `false`. Only `eq`/`neq` (and the unary `is_*`) tolerate a
missing field. Guarantee the field is present, or gate it behind an
`is_not_null` condition.

## Complexity

| Word | Cost |
|------|------|
| `cond` / `all-of` / `any-of` / `not-of` | `O(1)` (record construction) |
| `make-rule` / `make-table` / `with-policy` | `O(1)` |
| `make-branch` / `make-leaf` / `make-tree` | `O(1)` |
| `apply-op` | `O(1)` |
| `eval-cond` | `O(1)` |
| `eval-pred` | `O(children)` over the predicate group |
| `eval-table` / `decide` (table) | `O(rules)` — scans every rule under `first`/`unique`/`collect`/`priority` |
| `eval-tree` / `decide` (tree) | `O(depth)` — one branch hop per level, **capped at 100** hops |

A `first`-policy table still scans rules left to right and stops at the
first match; `unique`, `collect`, and `priority` always visit every
rule. A tree walk takes one hop per node and is bounded by the 100-hop
cap that surfaces `max-depth-exceeded` on a cycle.
