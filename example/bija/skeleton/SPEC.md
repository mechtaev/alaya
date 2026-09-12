# The Bija Language, version 1.0

Bija (Sanskrit *bīja*, "seed") is a small imperative language. Its name comes from the seeds
that Yogācāra Buddhism holds are deposited in the *ālaya-vijñāna*, the storehouse
consciousness: every act leaves an imprint, imprints accumulate, and later conditions cause
them to ripen. The language takes that literally.

Three things make Bija unlike most imperative languages, and everything else about it is
deliberately ordinary:

1. **A variable is a stack of generations, not a cell.** Assignment does not overwrite; it
   plants a new generation on top of the old ones, and every earlier generation stays readable
   through the `@` operator.
2. **A block can be undone.** An `attempt` block that reaches `wither` rolls the storehouse
   back to the state it had when the block began.
3. **An effect can be deferred until a condition ripens.** `ripen when` registers a block that
   runs later, at the first point where its condition holds.

This document specifies the language exactly. Where it says *error*, an implementation must
report an error; where it says *unspecified*, it must not.

---

## 1. Notation

Grammar rules use EBNF: `|` alternation, `{ }` zero or more, `[ ]` optional, `( )` grouping,
`"x"` a literal token. Nonterminals are lowercase. The grammar is over the token stream of §2.

---

## 2. Lexical structure

A source file is a sequence of Unicode characters encoded in UTF-8. It is converted to a token
stream by the rules below; the longest match wins at every position.

### 2.1 Whitespace and comments

Spaces (U+0020), tabs (U+0009), carriage returns (U+000D) and line feeds (U+000A) separate
tokens and are otherwise insignificant: Bija is free-form, and a statement may span any number
of lines.

A comment begins with `~~` and extends to the end of the line. It is whitespace.

### 2.2 Identifiers and keywords

```
identifier = ( "a".."z" | "_" ) { "a".."z" | "A".."Z" | "0".."9" | "_" }
```

An identifier must begin with a lowercase letter or an underscore. An identifier that begins
with an uppercase letter is an error.

The following are keywords and may not be used as identifiers:

```
and     attempt  deed    depth   each    end     give    in
no      not      or      otherwise        ripen   sow
utter   void     when    while   wither  yes
```

The names of the builtin deeds of §9 are not keywords, but a program may not define a deed
with one of those names (§7.1).

### 2.3 Literals

```
integer = "0".."9" { "0".."9" }
```

An integer literal denotes a non-negative integer of arbitrary size. Leading zeros are allowed
and insignificant. There is no floating-point type in Bija.

```
text = '"' { character | escape } '"'
escape = "\\" ( "\\" | '"' | "n" | "t" )
```

A text literal is delimited by double quotes. Inside it, `\\` denotes a backslash, `\"` a
double quote, `\n` a line feed, and `\t` a tab. Any other character other than `"` and `\`
stands for itself, including a literal line feed. A backslash followed by anything else is an
error. An unterminated text literal is an error.

`yes` and `no` are the flag literals; `void` is the void literal.

### 2.4 Operators and punctuation

```
=>   @   .   :   ,   (   )   [   ]
+    -   *   /   %   ^
=    <>  <   <=  >   >=
```

Note that `=` is *equality*. Bija has no assignment operator that looks like `=`; assignment is
written `=>` and flows to the right (§6.1).

---

## 3. Values and types

A Bija value has exactly one of five types.

| Type   | Values                                        |
| ------ | --------------------------------------------- |
| `int`  | integers of arbitrary size                     |
| `text` | finite sequences of Unicode characters         |
| `flag` | `yes` and `no`                                 |
| `void` | the single value `void`                        |
| `list` | finite sequences of values, of any types       |

**Every value is immutable.** No operation modifies a value in place; operations that appear to
extend a list (§9) return a new list. Consequently Bija has no aliasing and no identity: two
values are interchangeable exactly when they are equal by `=` (§5.6).

### 3.1 Rendering

`text(v)`, and the output of `utter` (§6.3), render a value as follows. The rendering of a
value depends on whether it appears at *top level* or *nested* inside a list.

| Value            | Top level                    | Nested                          |
| ---------------- | ---------------------------- | ------------------------------- |
| int `n`          | decimal digits, `-` if `n<0` | same                            |
| `yes` / `no`     | `yes` / `no`                 | same                            |
| `void`           | `void`                       | same                            |
| text `t`         | the characters of `t`        | `"` + escaped `t` + `"`         |
| list `[a, b, c]` | `[`, elements nested and separated by `, `, `]` | same         |

An empty list renders as `[]`. Escaping in the nested rendering of a text replaces `\` with
`\\`, `"` with `\"`, a line feed with `\n`, and a tab with `\t`; every other character stands
for itself.

Examples: `utter "hi".` prints `hi`; `utter ["hi", 3, no].` prints `["hi", 3, no]`.

---

## 4. The storehouse

### 4.1 Seeds and generations

A **seed** is a named, non-empty stack of values called its **generations**. The value at the
top of the stack is the seed's *current* value; the one below it is one generation older, and
so on. The number of generations is the seed's **depth**, which is at least 1.

`sow x` creates a seed named `x` with a single generation. Planting a value into an existing
seed (§6.1) pushes a generation; nothing is ever removed except by rollback (§6.8).

### 4.2 Scopes

A **scope** maps names to seeds. Scopes form a chain: each has at most one parent.

A new scope is created on entry to each of the following, and discarded on exit:

* the body of `when`, `otherwise`, `while` (one per iteration), `each` (one per iteration),
  `attempt`, and `ripen`;
* the body of a deed call, whose scope has **no parent**;
* the program itself, whose scope has no parent (the *root scope*).

Discarding a scope discards the seeds it holds, along with all of their generations.

**Resolving a name** means searching the current scope and then its ancestors, stopping at the
first scope that holds the name. Because a deed's scope has no parent, a deed body can name
only its own parameters and the seeds it sows itself: it cannot see, read, or plant into the
seeds of its caller or of the root scope. It is an error to resolve a name that is not found.

`sow x` always creates the seed in the *current* scope, and it is an error if the current scope
already holds a seed named `x`. Sowing a name that an *ancestor* scope holds is allowed, and
shadows it for the lifetime of the scope.

### 4.3 Pendings

Each scope also holds an ordered list of **pendings**, described in §6.9. A discarded scope
discards its pendings, which then never run.

---

## 5. Expressions

```
expression = disjunction
disjunction = conjunction { "or" conjunction }
conjunction = negation { "and" negation }
negation = "not" negation | comparison
comparison = sum [ ( "=" | "<>" | "<" | "<=" | ">" | ">=" ) sum ]
sum = product { ( "+" | "-" ) product }
product = unary { ( "*" | "/" | "%" ) unary }
unary = "-" unary | power
power = base [ "^" unary ]
base = "depth" identifier | postfix
postfix = primary { "(" [ arguments ] ")" | "[" expression "]" }
arguments = expression { "," expression }
primary = integer | text | "yes" | "no" | "void"
        | identifier [ "@" primary ]
        | "(" expression ")"
        | "[" [ arguments ] "]"
```

`or` and `and` are left-associative; `+ - * / %` are left-associative; `^` is
right-associative; comparison is non-associative, so `a < b < c` is a syntax error. Unary minus
binds tighter than any binary operator except `^`, so `-2^2` is `-(2^2)` = `-4`.

Evaluation is strict and left-to-right everywhere except in `and` and `or`, which are
short-circuiting (§5.5). Arguments of a call are evaluated left to right, before the call.

### 5.1 Literals and names

An integer, text, flag or void literal evaluates to the corresponding value. An identifier
evaluates to the current value of the seed it resolves to (§4.2).

A list expression `[e1, ..., en]` evaluates its elements left to right and yields the list of
their values. `[]` is the empty list.

### 5.2 Generation access

`x @ k` evaluates `k`, which must be an `int`, and yields the generation of the seed `x` that
is `k` generations older than the current one. `x @ 0` is exactly `x`. It is an error if `k` is
negative, and an error if `k` is greater than or equal to the depth of `x`.

The operand of `@` is always a single identifier: `f(a) @ 1` is a syntax error, and `x @ 1 @ 1`
is a syntax error. Its right operand is a *primary*, so `x @ n` and `x @ (n + 1)` are legal but
`x @ n + 1` parses as `(x @ n) + 1`.

### 5.3 `depth`

`depth x` yields the number of generations of the seed `x`, as an `int`. It is at least 1. The
operand is always a single identifier.

### 5.4 Arithmetic

`+ - * / % ^` require both operands to be `int`, except that `+` also accepts two `text` values
(concatenation) or two `list` values (concatenation). Any other combination is an error, and in
particular Bija never coerces between types.

* `/` is division rounding toward negative infinity: `7 / 2` is `3`, `-7 / 2` is `-4`.
* `%` is the remainder of that division, so its sign follows the divisor: `-7 % 2` is `1`.
* `/` and `%` by zero are errors.
* `^` requires a non-negative right operand; a negative exponent is an error.
* Unary `-` requires an `int`.

### 5.5 Logic

`not e` requires `e` to be a `flag` and yields its negation.

`a and b` evaluates `a`, which must be a `flag`. If it is `no`, the result is `no` and `b` is
not evaluated. Otherwise the result is `b`, which must be a `flag`.

`a or b` evaluates `a`, which must be a `flag`. If it is `yes`, the result is `yes` and `b` is
not evaluated. Otherwise the result is `b`, which must be a `flag`.

Bija has no notion of truthiness: only `flag` values are conditions.

### 5.6 Comparison

`=` and `<>` accept any two values and never fail. Two values are equal when they have the same
type and:

* two ints are numerically equal;
* two texts are the same sequence of characters;
* two flags are both `yes` or both `no`;
* `void` equals `void`;
* two lists have the same length and equal elements, pairwise.

Values of different types are never equal, so `1 = yes` is `no` rather than an error.

`< <= > >=` require both operands to be `int`, or both to be `text`. Texts are ordered
lexicographically by Unicode code point. Any other operand types are an error.

### 5.7 Indexing

`e[i]` requires `e` to be a `text` or a `list` and `i` to be an `int`. Indices are 0-based.
Negative indices are an error — Bija does not index from the end — as is an index greater than
or equal to the length. Indexing a text yields a text of length 1.

### 5.8 Calls

`f(a1, ..., an)` calls the deed named `f` (§7) or the builtin deed of that name (§9). The name
must be resolvable at compile time, and the number of arguments must match the deed's; both are
compile-time errors otherwise. A call is an expression and yields the deed's result.

---

## 6. Statements

```
statement = plant | sow | utter | when | while | each | deed
          | give | attempt | wither | ripen | effect
```

**Every statement ends with a full stop `.`**, including the block statements: the `end` of a
`when` is followed by `.`.

A **block** is a sequence of zero or more statements. Statements run in order.

### 6.1 Planting

```
plant = expression "=>" ( identifier | "sow" identifier ) "."
```

`e => x.` evaluates `e` and pushes its value as a new generation of the seed that `x` resolves
to. The seed's earlier generations remain readable through `@`. It is an error if `x` does not
resolve.

`e => sow x.` evaluates `e`, creates a seed named `x` in the current scope with that value as
its single generation, and is an error if the current scope already holds `x`.

### 6.2 Sowing

```
sow = "sow" identifier "."
```

`sow x.` creates a seed named `x` in the current scope whose single generation is `void`. It is
equivalent to `void => sow x.`.

### 6.3 Uttering

```
utter = "utter" expression "."
```

Evaluates the expression, renders it at top level (§3.1), and writes the rendering followed by
a line feed to standard output. Output is written when the statement runs and is never undone
by a rollback (§6.8).

### 6.4 Conditionals

```
when = "when" expression ":" block [ "otherwise" ":" block ] "end" "."
```

Evaluates the condition, which must be a `flag`. If it is `yes`, the first block runs in a new
scope; otherwise the `otherwise` block, if present, runs in a new scope.

### 6.5 While loops

```
while = "while" expression ":" block "end" "."
```

Evaluates the condition, which must be a `flag`, before each iteration. While it is `yes`, the
block runs in a **fresh scope per iteration** — so a seed sown in the body starts each
iteration with a depth of 1, and cannot be read across iterations.

### 6.6 Each loops

```
each = "each" identifier "in" expression ":" block "end" "."
```

Evaluates the expression, which must be a `list` or a `text`. For each element in order — the
elements of a list, or the one-character texts of a text — a fresh scope is created, a seed
with the loop's name is sown in it with that element as its value, and the block runs. The
sequence is evaluated once, before the first iteration; because values are immutable, nothing
can change it during the loop.

### 6.7 Deeds and giving

```
deed = "deed" identifier "(" [ identifier { "," identifier } ] ")" ":" block "end" "."
give = "give" [ expression ] "."
```

See §7.

### 6.8 Attempt and wither

```
attempt = "attempt" ":" block "end" "."
wither = "wither" "."
```

`attempt` records a **mark** — the depth of every seed reachable from the current scope — and
then runs its block in a new scope.

If the block finishes normally, nothing is undone: the mark is discarded and execution
continues after `end`.

If `wither` runs at any point during the *dynamic extent* of the block — including inside a
deed called from it, however deeply — control leaves the block immediately and the storehouse
is rolled back to the mark:

* every seed that existed at the mark has its generations above the marked depth removed, so
  its current value is again the value it had when the `attempt` began;
* every scope created inside the block is discarded, and with it every seed sown there;
* every pending registered inside the block is discarded, and never runs.

Execution then continues with the statement after `end.`, exactly as if the block had finished
normally.

`wither` unwinds to the innermost `attempt` in the dynamic extent. It is an error to run
`wither` when there is no such `attempt`.

Note what is *not* undone: output already written (§6.3). A rollback restores the storehouse,
not the world.

### 6.9 Ripening

```
ripen = "ripen" "when" expression ":" block "end" "."
```

`ripen when c: b end.` does **not** evaluate `c` and does not run `b`. It registers a
*pending*, holding the unevaluated condition and block, at the end of the pending list of the
scope in which the statement appears.

A **checkpoint** happens immediately after each statement of a block finishes, in the scope of
that block. At a checkpoint, the scope's pending list is scanned from its first element:

* the pending's condition is evaluated, in the scope that holds the pending, and must be a
  `flag`;
* if it is `no`, the scan moves to the next pending, and the pending stays in the list;
* if it is `yes`, the pending is removed from the list, and its block runs in a new scope whose
  parent is the scope that held the pending;
* the scan then continues with the pending that now follows the position just examined;
* the scan ends when it passes the end of the list.

A checkpoint therefore runs each pending at most once, in registration order, and can cascade:
a block that ripens early in the scan may make a later pending's condition true, and that one
then ripens in the same checkpoint.

A pending belongs to exactly one scope: the one holding the block in which its `ripen`
statement appears. A `ripen` inside a ripened block therefore registers in that block's own
scope, is checked at that block's checkpoints, and is discarded when it ends.

The checkpoint after a `ripen` statement itself is an ordinary checkpoint, so a pending whose
condition already holds ripens immediately after being registered.

Pendings still in the list when their scope is discarded never run — a `ripen` whose condition
never becomes true simply does not happen. In particular, a pending registered in a `while`
body is discarded at the end of that iteration.

A `give` inside the block of a `ripen` is a compile-time error, because the block does not run
as part of the deed's control flow. A `wither` inside it is allowed and behaves as in §6.8.

### 6.10 Effect statements

```
effect = expression "."
```

Evaluates the expression and discards its value. Its purpose is calling a deed for its output.

---

## 7. Deeds

```
deed = "deed" identifier "(" [ parameters ] ")" ":" block "end" "."
```

A deed is a named procedure. Deeds may be declared only at the top level of a program, never
inside another statement, and a program may not declare two deeds with the same name, nor a
deed whose name is that of a builtin (§9). Deeds are not values: a name may be used as a deed
only in a call.

Because deed declarations are gathered before the program runs, a deed may call a deed declared
later in the file, and may call itself.

### 7.1 Calling

A call evaluates its arguments left to right, creates a **parentless** scope, sows one seed per
parameter in that scope with the corresponding argument value, and runs the body in it. The
parameters are ordinary seeds: they may be planted into, and their generations accumulate as
usual.

`give e.` evaluates `e` and ends the call with that value. `give.` ends the call with `void`. A
body that finishes without giving yields `void`.

Recursion is permitted. An implementation may impose a limit on recursion depth; exceeding it
is an error.

---

## 8. Programs

```
program = { statement }
```

A program is a block, run in the root scope. Deed declarations anywhere in it are collected
before execution and are not themselves executed. The program ends when its last statement has
finished, or when a runtime error occurs.

### 8.1 Errors

A **compile-time error** is a violation of §2 (lexical), §5–§8 (syntactic), or one of these
static rules: an unknown deed name in a call, a wrong number of arguments, a duplicate deed
name, a deed named after a builtin, a deed declared other than at the top level, a `give`
outside a deed, and a `give` inside a `ripen` block. An implementation must report the first
such error with its line and column, and must not run the program.

A **runtime error** is any of the conditions this document calls an error at run time. It ends
the program immediately: no further statement runs, and no pending ripens. Output already
written stands.

A program that completes normally succeeds. A program that fails at compile time or at run time
fails, and the two are distinguishable by the reported message.

---

## 9. Builtin deeds

Builtins are called like deeds. Their argument types are checked, and a mismatch is a runtime
error.

| Call                     | Result                                                                 |
| ------------------------ | ---------------------------------------------------------------------- |
| `len(v)`                 | length of a text or a list, as an `int`                                 |
| `push(l, v)`             | a new list: the elements of list `l` followed by `v`                    |
| `slice(s, a, b)`         | elements `a` up to but excluding `b` of a text or list                  |
| `join(l, sep)`           | the texts in list `l` joined by text `sep`                              |
| `chars(t)`               | the list of one-character texts of text `t`                             |
| `text(v)`                | the top-level rendering of any value (§3.1), as a text                  |
| `number(t)`              | the integer denoted by text `t`                                         |
| `range(a, b)`            | the list `[a, a+1, ..., b-1]`, empty when `a >= b`                       |
| `has(s, v)`              | `yes` when value `v` occurs in list `s`, or text `v` occurs in text `s` |

* `slice` requires `0 <= a <= b <= len(s)`; anything else is an error.
* `join` requires every element of `l` to be a text.
* `number` accepts an optional `-` followed by one or more decimal digits and nothing else; any
  other text is an error.
* `range` requires two ints.
* `has` on a text requires `v` to be a text, and tests for a contiguous substring; the empty
  text occurs in every text.

---

## 10. A complete example

```
~~ Collatz, with a rollback and a deferred report.

deed step(n):
  when n % 2 = 0:
    give n / 2.
  otherwise:
    give 3 * n + 1.
  end.
end.

27 => sow n.
0 => sow steps.

ripen when n = 1:
  utter "reached 1 in " + text(steps) + " steps".
end.

while n <> 1:
  step(n) => n.
  steps + 1 => steps.
end.

utter "highest generation still readable: " + text(n@steps).

attempt:
  999 => n.
  utter "inside: " + text(n).
  wither.
end.

utter "after wither: " + text(n).
```

This prints:

```
reached 1 in 111 steps
highest generation still readable: 27
inside: 999
after wither: 1
```

The pending ripens at the first checkpoint after `n` becomes 1 — that is, after the assignment
in the loop body's enclosing block, which is the program block, so it ripens after the `while`
statement finishes. The generation `n@steps` is the value `n` held 111 assignments ago, the
seed's original 27. The `attempt` plants 999, utters it, and withers, so the last statement
sees 1 again, but the `inside:` line has already been written and stays.
