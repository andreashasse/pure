defmodule Pure do
  @moduledoc """
  Static purity analysis for BEAM functions.

  A function is *pure* here if calling it does nothing but compute a
  return value: no messages, no process dictionary, no ETS, no clock, no
  I/O, nothing that makes a second call to it observably different from
  the first. Raising is still pure — an exception is a result, not an
  effect.

      Pure.analyze(modules: [MyApp.Core])

  ## Verdicts

    * `:pure`
    * `{:conditional, positions}` - pure as long as the funs passed at
      these argument positions are pure, e.g. `def apply_all(list, f)`
    * `{:impure, reasons}` - reaches an effect
    * `{:unknown, reasons}` - the analyser lost the trail: a dynamic
      `apply/3`, a fun it could not resolve, or a module it has no
      knowledge of and could not read

  `{:unknown, _}` is deliberately not folded into either of the other
  two. Reporting a guess as a fact is the one thing this tool must not
  do.

  ## Annotating functions

      defmodule MyApp.Core do
        use Pure

        @pure true
        def total(items), do: Enum.sum_by(items, & &1.amount)
      end

  `mix pure --check` then fails the build if `total/1` ever stops being
  pure. Erlang modules can use `-pure_annotated([{total, 1}]).`

  ## What it cannot see

    * Dynamic dispatch. `apply/3` on computed values is `:unknown`, as
      is a fun stored in a data structure and applied later.
    * Protocol dispatch is assumed pure, so `Enumerable`, `Collectable`
      and `Inspect` implementations are taken on trust.
    * Creating a fun counts as calling it: `fn -> IO.puts("hi") end`
      makes the enclosing function impure even if it is never applied.
    * The knowledge base is hand-maintained. It covers OTP and Elixir's
      standard library; anything else is `:unknown` until told
      otherwise through `:known`.
    * Non-termination, allocation and atom table growth are not
      effects here.
  """

  alias Pure.{Analyzer, Beam}

  @type analysis :: %{results: %{mfa() => Analyzer.result()}, skipped: [Beam.failure()]}

  # Compiler-generated functions that say nothing about the code as written.
  @generated [{:module_info, 0}, {:module_info, 1}, {:__info__, 1}]

  # Macros compile to `MACRO-name/arity`. They run at compile time, where
  # purity is a different question, so they are left out of reports.
  @macro_prefix "MACRO-"

  @doc """
  Analyse modules, directories or `.beam` files.

  Options:

    * `:modules` - modules to analyse
    * `:paths` - directories or `.beam` files to analyse
    * `:known` - `%{mfa => Pure.Knowledge.answer}` overrides for
      functions the built-in knowledge base does not cover

  Everything reachable but not listed is resolved through
  `Pure.Knowledge`, so analysing a single module still gives useful
  answers about its calls into OTP and Elixir.
  """
  @spec analyze(keyword()) :: analysis()
  def analyze(opts \\ []) do
    targets = Keyword.get(opts, :modules, []) ++ Keyword.get(opts, :paths, [])
    {forms, skipped} = Beam.load(targets)
    %{results: Analyzer.analyze(forms, Keyword.take(opts, [:known])), skipped: skipped}
  end

  @doc """
  The verdict for one function, `:not_analyzed` if it was not part of the run.

      iex> analysis = Pure.analyze(modules: [Pure.Knowledge])
      iex> Pure.verdict(analysis, {Pure.Knowledge, :describe, 1})
      :pure
  """
  @spec verdict(analysis(), mfa()) :: Analyzer.verdict() | :not_analyzed
  def verdict(%{results: results}, mfa) do
    case Map.fetch(results, mfa) do
      {:ok, result} -> result.verdict
      :error -> :not_analyzed
    end
  end

  @doc """
  Whether a function is known to be pure.

  Both `{:unknown, _}` and `{:conditional, _}` answer `false`: neither is
  a promise.

      iex> analysis = Pure.analyze(modules: [Pure.Knowledge])
      iex> Pure.pure?(analysis, {Pure.Knowledge, :lookup, 3})
      true
  """
  @spec pure?(analysis(), mfa()) :: boolean()
  def pure?(analysis, mfa), do: verdict(analysis, mfa) == :pure

  @doc """
  Functions annotated `@pure true` whose verdict is not `:pure`.

  This is what `mix pure --check` fails on.
  """
  @spec violations(analysis()) :: [{mfa(), Analyzer.verdict()}]
  def violations(%{results: results}) do
    for {mfa, %{annotated: true, verdict: verdict}} <- results,
        verdict != :pure,
        do: {mfa, verdict}
  end

  @doc """
  Whether a function is compiler-generated or compile-time only.

      iex> Pure.generated?({MyApp, :module_info, 0})
      true

      iex> Pure.generated?({MyApp, :"MACRO-defthing", 2})
      true

      iex> Pure.generated?({MyApp, :total, 1})
      false
  """
  @spec generated?(mfa()) :: boolean()
  def generated?({_module, function, arity}) do
    {function, arity} in @generated or
      String.starts_with?(Atom.to_string(function), @macro_prefix)
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :pure, persist: false)
      Module.register_attribute(__MODULE__, :pure_annotated, accumulate: true, persist: true)
      @on_definition Pure
    end
  end

  @doc false
  def __on_definition__(env, kind, name, args, _guards, _body) when kind in [:def, :defp] do
    if Module.get_attribute(env.module, :pure) do
      Module.delete_attribute(env.module, :pure)
      Module.put_attribute(env.module, :pure_annotated, {name, length(args)})
    end
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok
end
