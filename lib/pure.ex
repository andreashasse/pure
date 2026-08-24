defmodule Pure do
  @moduledoc """
  Static purity analysis for BEAM functions.

  A function is *pure* here if calling it does nothing but compute a
  return value: no messages, no process dictionary, no ETS, no clock, no
  I/O, nothing that makes a second call to it observably different from
  the first. Raising is still pure — an exception is a result, not an
  effect.

      Pure.analyze(modules: [MyApp.Core])

  ## Dispatch

  A call that picks its target at runtime is only as pure as the
  implementations it can reach, so all of them have to be pure for the
  dispatch to be pure. Protocols and behaviours go through one rule: a
  call to a module that declares the callback joins over its
  implementations, and a literal at the call site narrows that to the
  one implementation it will reach.

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

        @pure_module true

        @pure except: [:time]
        def stamp(item), do: %{item | at: DateTime.utc_now()}
      end

  `mix pure --check` then fails the build if any of it stops being true.
  `except:` waives whole classes of effect for the one function that
  wrote it: a caller annotated plain `@pure` still fails on the clock its
  callee reads. `@pure_module` makes the claim for every public function
  in the module, including the ones written tomorrow, and a function may
  narrow what its module waives but not widen it.

  Erlang modules write the same two things as
  `-pure_annotated([{total, 1}, {stamp, 1, [time]}]).` and
  `-pure_module([{except, [time]}]).`

  Projects that run Credo can have the same answers as Credo issues, on
  the line the annotation sits on, by adding `Pure.Check.Purity` to
  `.credo.exs`.

  ## What it cannot see

    * Dynamic dispatch. `apply/3` on computed values is `:unknown`, as
      is a fun stored in a data structure and applied later.
    * A dispatch joins over the implementations that are part of the
      analysis. One that was never compiled into the project cannot be
      accounted for.
    * `Kernel.inspect/1` is trusted rather than dispatched through
      `Inspect`.
    * Creating a fun counts as calling it: `fn -> IO.puts("hi") end`
      makes the enclosing function impure even if it is never applied.
    * The knowledge base is hand-maintained. It covers OTP and Elixir's
      standard library; anything else is `:unknown` until told
      otherwise through `:known`.
    * Non-termination, allocation and atom table growth are not
      effects here.
  """

  alias Pure.{Analyzer, Annotation, Beam}

  @type analysis :: %{results: %{mfa() => Analyzer.result()}, skipped: [Beam.failure()]}

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

    {forms, skipped} =
      targets
      |> Beam.load()
      |> Beam.load_implementations()

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
  Annotated functions whose verdict does not keep what the annotation claimed.

  The classes an annotation waives are dropped first, so a function
  annotated `@pure except: [:time]` appears here only for the effects it
  did not own up to. This and `annotation_problems/1` are what
  `mix pure --check` fails on.
  """
  @spec violations(analysis()) :: [{mfa(), Analyzer.verdict()}]
  def violations(%{results: results}) do
    violations =
      for {mfa, %{annotation: %{except: except}, verdict: verdict}} <- results,
          {:violation, unwaived} <- [Annotation.check(verdict, except)],
          do: {mfa, unwaived}

    Enum.sort(violations)
  end

  @doc """
  Waivers that have outlived the effect they were written for.

  `@pure except: [:time]` on a function that no longer reads the clock is
  not wrong, only untrue, so this is reported apart from `violations/1`
  and never fails a build on its own.

  A `@pure_module` waiver is judged over the module rather than over each
  function it covers: it exists so that *some* function may read the
  clock, and the ones that do not are the point of the annotation, not a
  finding.
  """
  @spec stale_waivers(analysis()) :: [{mfa() | module(), [Pure.Knowledge.category()]}]
  def stale_waivers(%{results: results}) do
    per_function =
      for {mfa, %{annotation: %{except: except, scope: :function}, effects: effects}} <- results,
          except != [],
          stale = Annotation.stale(effects, except),
          stale != [],
          do: {mfa, stale}

    Enum.sort(per_function ++ per_module(results))
  end

  defp per_module(results) do
    results
    |> Enum.filter(&match?({_mfa, %{annotation: %{scope: :module}}}, &1))
    |> Enum.group_by(fn {{module, _function, _arity}, _result} -> module end)
    |> Enum.flat_map(fn {module, covered} ->
      [{_mfa, %{annotation: %{except: except}}} | _rest] = covered
      effects = Enum.flat_map(covered, fn {_mfa, result} -> result.effects end)

      case Annotation.stale(effects, except) do
        [] -> []
        stale -> [{module, stale}]
      end
    end)
  end

  @doc """
  Annotations that are wrong in themselves: a misspelt effect class, a
  value that is neither `true` nor `except: [...]`, or a function waiving
  more than its module's `@pure_module` allows.

  A problem with the module's own annotation is reported against the
  module rather than once per function it covers.
  """
  @spec annotation_problems(analysis()) :: [{mfa() | module(), Annotation.problem()}]
  def annotation_problems(%{results: results}) do
    found =
      for {mfa, %{annotation: %{problems: problems, scope: scope}}} <- results,
          problem <- problems,
          do: {subject(scope, mfa), problem}

    found |> Enum.uniq() |> Enum.sort()
  end

  defp subject(:module, {module, _function, _arity}), do: module
  defp subject(:function, mfa), do: mfa

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
  defdelegate generated?(mfa), to: Analyzer

  @doc false
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :pure, persist: false)
      Module.register_attribute(__MODULE__, :pure_module, persist: true)
      Module.register_attribute(__MODULE__, :pure_annotated, accumulate: true, persist: true)
      @on_definition Pure
      @before_compile Pure
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    case Module.get_attribute(env.module, :pure_module) do
      nil -> :ok
      value -> parse!(value, Annotation.subject(env.module))
    end

    quote do
    end
  end

  @doc false
  def __on_definition__(env, kind, name, args, _guards, _body) when kind in [:def, :defp] do
    case Module.get_attribute(env.module, :pure) do
      nil ->
        :ok

      value ->
        Module.delete_attribute(env.module, :pure)
        except = parse!(value, Annotation.subject({env.module, name, length(args)}))
        defaults = Enum.count(args, &match?({:\\, _meta, [_argument, _default]}, &1))

        for arity <- Annotation.arities(length(args), defaults) do
          Module.put_attribute(env.module, :pure_annotated, entry(name, arity, except))
        end
    end
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  # An empty waiver list keeps the two-element shape the attribute has
  # always had, which is also what Erlang's -pure_annotated writes.
  defp entry(name, arity, []), do: {name, arity}
  defp entry(name, arity, except), do: {name, arity, except}

  # A misspelt effect class waives nothing, so failing the compile beats
  # letting the annotation look stricter than it is.
  defp parse!(value, subject) do
    case Annotation.parse(value) do
      {:ok, except} ->
        except

      {:error, problem} ->
        raise ArgumentError, "#{subject} #{Annotation.describe_problem(problem)}"
    end
  end
end
