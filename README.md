# pure

A Mix task that tells you which functions have side effects.

```
$ mix pure --all

Payments.Core
  fee/2                           pure
  settle/2                        pure if the fun given as argument 2 is pure
  charge/2                        impure: performs I/O (IO.puts/1) via Payments.Core.log/1

1 pure, 1 conditional, 1 impure, 0 unknown (3 functions)
```

It reads the abstract code out of compiled `.beam` files, so it works on
both Elixir and Erlang, sees your code after macro expansion, and needs
no annotations to say something useful. Calls into your dependencies are
followed too, so an effect three libraries deep still comes back with
the function that has it.

## Install

```elixir
def deps do
  [{:pure, "~> 0.1", only: [:dev, :test], runtime: false}]
end
```

## Use

```bash
mix pure                     # every module in the project
mix pure Payments.Core       # one module
mix pure Payments.Core.fee/2 # one function
mix pure --check             # fail the build if a @pure function is not pure
```

| Option | Effect |
| --- | --- |
| `--check` | Exit non-zero when a function annotated `@pure true` is not pure. The CI mode. |
| `--all` | List pure functions too. |
| `--no-deps` | Do not follow calls into dependencies. Faster, at the cost of reporting every call into a library as unknown. |
| `--unknown` | List functions whose purity could not be determined. |
| `--private` | Include private functions. |

## Verdicts

**`pure`** — computes a return value and nothing else. Raising is still
pure: an exception is a result, not an effect.

**`conditional`** — pure as long as the funs passed at the given
argument positions are pure. `def each(list, fun)` is not impure, it is
*someone else's* purity. Call sites are resolved individually, so
`Enum.map(list, &String.upcase/1)` is pure while
`Enum.map(list, &IO.puts/1)` is not.

**`impure`** — reaches an effect, reported with the function that has it
and the callee it came in through:

```
charge/2   impure: performs I/O (IO.puts/1) via Payments.Core.log/1
```

**`unknown`** — the trail was lost: an `apply/3` with a computed module,
a fun the analyser could not resolve, or a module it has no knowledge of
and could not read.

That fourth verdict is the point. Folding "cannot tell" into either
"pure" or "impure" would make every other answer untrustworthy.

## Annotating

```elixir
defmodule Payments.Core do
  use Pure

  @pure true
  def fee(amount, rate), do: round(amount * rate)
end
```

`mix pure --check` now fails if `fee/2` ever grows an effect — a
functional core that stays a functional core. In Erlang:

```erlang
-pure_annotated([{fee, 2}]).
```

## Teaching it about a library

Unknown functions are reported, never guessed. When you know better than
the analyser, say so in `mix.exs`:

```elixir
def project do
  [
    pure: [
      known: %{
        {MyLib.Cache, :get, 1} => {:impure, :ets},
        {MyLib.Money, :add, 2} => :pure,
        {MyLib.Fold, :run, 2} => {:hof, [2]}
      }
    ]
  ]
end
```

## Dispatch

A call that picks its target at runtime is only as pure as the
implementations it can reach, so **all of them have to be pure for the
dispatch to be pure**. A protocol is just a behaviour whose
implementations live in their own modules, so both go through one rule:
a call to a module that declares the callback joins over the
implementations.

```elixir
defimpl String.Chars, for: Loud do
  def to_string(loud) do
    IO.puts("converting")   # one impure implementation is enough
    loud.name
  end
end

"hello #{term}"             # impure: it can reach that implementation
```

When the call site says which implementation it will reach, only that
one counts:

```elixir
for x <- xs, into: %{}      # pure — only Collectable.Map can be reached
for x <- xs, into: stream   # impure if a reachable Collectable writes
```

The same holds without a module name at all, because the *function* name
is often enough — `calendar.date_to_string(y, m, d)` names no module,
but `date_to_string/3` is a `Calendar` callback, so the implementations
are known.

Implementations are found without being asked for: analysing a module
pulls in the protocols it dispatches to along with their
implementations.

## How it works

1. **Scan.** Every function body is walked for the things that can have
   an effect: calls, fun references, `!`, `receive`. Each call argument
   keeps a shape — a resolvable fun, a parameter of the enclosing
   function, a literal of a known type, or opaque.
2. **Resolve.** Each call becomes a dependency on another analysed
   function, a set of dependencies on the implementations it dispatches
   to, a known effect, or an unknown. Applying a parameter makes the
   function higher-order at that position rather than impure.
3. **Fixpoint.** Effects propagate backwards along the call graph until
   nothing changes. Recursion needs no special case: the least fixpoint
   starts at "no effects" and only grows.

Leaves of the call graph are BIFs and NIFs whose abstract code shows
nothing — `:ets.insert/2` compiles to `erlang:nif_error(undef)`, and
believing that would report it as pure. `Pure.Knowledge` is the
hand-maintained table that stops the analysis from bottoming out in a
lie, and it always wins over what the code appears to do.

## What it cannot see

- **Dynamic dispatch.** `apply(module, fun, args)` on computed values is
  `unknown`, as is a fun that was stored in a data structure and applied
  later. A dispatch is only resolved when the callback name is known.
- **Only the implementations it can see.** A dispatch joins over the
  implementations in the analysis. One that is never compiled into the
  project — loaded at runtime, or in an application that was not
  analysed — cannot be accounted for.
- **`Kernel.inspect/1` is trusted.** Inspecting is treated as pure
  rather than dispatched through `Inspect`, which would make almost
  every debug helper impure.
- **Creating a fun counts as calling it.** `fn -> IO.puts("hi") end`
  makes the enclosing function impure even if the fun is never applied.
  Deliberately conservative.
- **The knowledge base is hand-maintained.** It covers OTP and Elixir's
  standard library; anything else is `unknown` until you teach it.
- **Determinism is not proven.** Non-termination, allocation, atom table
  growth and scheduling are not effects here.

## Development

```bash
mix test
mix test --cover
mix pure --all   # it analyses itself
```

Running it on itself reports every function of the analysis core as
pure, and every function that touches beam files or Mix as impure.
