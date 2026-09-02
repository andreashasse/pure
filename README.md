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
| `--check` | Exit non-zero when an annotation is not kept. The CI mode. |
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
functional core that stays a functional core.

A function that owns up to one kind of effect says which:

```elixir
@pure except: [:time]
def quote(amount), do: {DateTime.utc_now(), fee(amount, 0.03)}
```

The waiver belongs to `quote/1` and to nothing else. A caller annotated
plain `@pure` still fails on the clock its callee reads, which is what
stops a waiver from laundering effects through the rest of the call
graph. Telling the analyser about code it cannot see is a different job,
and `:known` below is where that lives.

A whole module can make the claim at once, which is the useful form for a
functional core: a function added to it tomorrow is covered the day it
lands.

```elixir
defmodule Payments.Core do
  use Pure

  @pure_module except: [:time]

  def fee(amount, rate), do: round(amount * rate)
end
```

A module-wide claim covers every public function and no private one. A
function inside it may narrow what its module waives, never widen it. To
exempt one function entirely, use Credo's own
`# credo:disable-for-next-line Pure.Check.Purity`.

The classes an annotation may name are the ones the analyser reports:
`:io`, `:file`, `:network`, `:system`, `:time`, `:random`, `:process`,
`:process_dictionary`, `:message`, `:message_receive`, `:ets`,
`:persistent_term`, `:mutable_state`, `:code_loading`, `:port`,
`:tracing`, and the three that mean the trail was lost rather than an
effect found: `:dynamic_call`, `:higher_order` and `:unknown`. A
misspelt one is an error rather than a waiver of nothing, and fails the
compile.

Two verdicts keep a claim rather than breaking it. A higher-order
function is pure in itself — whoever hands it `&IO.puts/1` fails on
their own annotation — so `conditional` passes. `unknown` does not: an
annotation nobody can check is the case this tool exists to report, and
waiving it takes saying `except: [:unknown]`.

In Erlang:

```erlang
-pure_annotated([{fee, 2}, {quote, 1, [time]}]).
-pure_module([{except, [time]}]).
```

## As a Credo check

If the project already runs Credo, the same answers arrive as ordinary
Credo issues, on the line the annotation sits on:

```elixir
# .credo.exs
%{
  configs: [
    %{
      name: "default",
      checks: %{extra: [{Pure.Check.Purity, []}]}
    }
  ]
}
```

```
┃ [W] ↗ charge/2 is annotated @pure but is impure: performs I/O
┃       (IO.puts/1) via Payments.Core.log/1
┃       lib/payments/core.ex:24:7 #(Payments.Core.charge)
```

Credo has to be a dependency of your project for the check to exist:
this library declares it as optional, so without it the check is not
compiled at all and `pure` still brings nothing with it.

```elixir
{:credo, "~> 1.7", only: [:dev, :test], runtime: false}
```

| Param | Effect |
| --- | --- |
| `known` | The same `%{mfa => answer}` map as `mix.exs`, merged over it. |
| `follow_deps` | Follow calls into dependencies. On by default; without it, a call into a library is `unknown` and an annotation that reaches one cannot be kept. |

The check reads annotations from the source and answers from the
compiled code, which has three consequences worth knowing:

- **Compile first.** The check never compiles anything itself. A module
  missing from the build, or older than the file it was compiled from,
  is reported as unchecked rather than quietly passed. Run `mix compile`
  before `mix credo` in CI.
- **One analysis per run.** Purity is a property of the call graph, not
  of a file, so the whole project is analysed once and every annotation
  in the run reads its answer from that. A module in the call graph of
  forty annotated functions is read, scanned and settled exactly once.
  A project with no annotations at all pays nothing: the check looks for
  them first and stops there.
- **A `def` written by a macro has no annotation in the source to
  find.** `mix pure --check` reads the compiled attribute instead, and
  stays the way to cover those, along with Erlang modules.

A waiver that has outlived the effect it was written for is reported
too, at low priority and with no exit status of its own: an annotation
that is merely out of date says something untrue about the code, but it
cannot make the check miss anything, so it does not fail a build.

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
