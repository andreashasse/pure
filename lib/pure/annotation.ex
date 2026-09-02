defmodule Pure.Annotation do
  @moduledoc """
  What `@pure` and `@pure_module` claim, and whether a verdict keeps the claim.

  An annotation is a question put to the analysis, never an answer given to
  it. Nothing in this module changes a verdict; it only decides whether a
  verdict satisfies what was written above the function.

      @pure true                  # computes a result and nothing else
      @pure except: [:time]       # ... except that it reads the clock

  A waiver is not inherited. A caller annotated plain `@pure` still fails
  on the clock its callee reads, which is what stops a waiver from
  laundering effects through the rest of the call graph. Telling the
  analyser something it cannot see is a different job, and `:known` in
  `mix.exs` is where that lives.

  ## What passes

  `{:conditional, _}` keeps the claim: `def each(list, fun)` is pure in
  itself, and a caller that hands it `&IO.puts/1` fails on its own
  annotation instead. `{:unknown, _}` does not: an annotation the analyser
  cannot check is exactly the case this tool exists to report, and waiving
  it takes saying so with `except: [:unknown]`.
  """

  # This module cannot annotate itself. `Pure.__on_definition__/6` reads
  # `@pure` by calling `parse/1` and `describe_problem/1` right here, and
  # a module still being compiled cannot answer a call.
  alias Pure.{Analyzer, Knowledge}

  @typedoc """
  A parsed annotation.

  `scope` is `:module` for a function covered by its module's
  `@pure_module` rather than by an annotation of its own.
  """
  @type t :: %{
          except: [Knowledge.category()],
          scope: :function | :module,
          problems: [problem()]
        }

  @typedoc "Something wrong with the annotation itself, rather than with the function."
  @type problem ::
          {:unknown_effects, [term()]}
          | {:widens, [Knowledge.category()]}
          | {:invalid, term()}

  @doc """
  Read the value written after `@pure` or `@pure_module`.

      iex> Pure.Annotation.parse(true)
      {:ok, []}

      iex> Pure.Annotation.parse(except: [:time])
      {:ok, [:time]}

      iex> Pure.Annotation.parse(except: [:tyme])
      {:error, {:unknown_effects, [:tyme]}}

      iex> Pure.Annotation.parse(:yes)
      {:error, {:invalid, :yes}}
  """
  @spec parse(term()) :: {:ok, [Knowledge.category()]} | {:error, problem()}
  def parse(true), do: {:ok, []}

  def parse(value) when is_list(value) do
    if Keyword.keyword?(value) and Keyword.keys(value) == [:except] do
      value |> Keyword.fetch!(:except) |> effects()
    else
      {:error, {:invalid, value}}
    end
  end

  def parse(value), do: {:error, {:invalid, value}}

  defp effects(effects) when is_list(effects) do
    case Enum.reject(effects, &(&1 in Knowledge.categories())) do
      [] -> {:ok, effects |> Enum.uniq() |> Enum.sort()}
      unknown -> {:error, {:unknown_effects, Enum.uniq(unknown)}}
    end
  end

  defp effects(other), do: {:error, {:invalid, other}}

  @doc """
  Build the annotation for one function.

  `within` is the waiver list of the enclosing `@pure_module`, or `nil`
  when the module carries no annotation. A function may narrow what its
  module waives but not widen it, so anything it adds is recorded as a
  problem rather than quietly granted.
  """
  @spec build({:ok, [Knowledge.category()]} | {:error, problem()}, :function | :module, [
          Knowledge.category()
        ]) :: t()
  def build(parsed, scope, within \\ nil)

  def build({:error, problem}, scope, _within) do
    %{except: [], scope: scope, problems: [problem]}
  end

  def build({:ok, except}, scope, within) do
    %{except: except, scope: scope, problems: widening(except, within)}
  end

  defp widening(_except, nil), do: []

  defp widening(except, within) do
    case except -- within do
      [] -> []
      widened -> [{:widens, widened}]
    end
  end

  @doc """
  Whether a verdict keeps what the annotation claimed.

  The waived classes are dropped from the reasons; what is left, if
  anything, is the verdict the annotation failed on.

      iex> Pure.Annotation.check({:impure, [{:time, {DateTime, :utc_now, 0}, nil}]}, [:time])
      :ok

      iex> Pure.Annotation.check({:impure, [{:io, {IO, :puts, 1}, nil}]}, [:time])
      {:violation, {:impure, [{:io, {IO, :puts, 1}, nil}]}}

      iex> Pure.Annotation.check({:conditional, [2]}, [])
      :ok
  """
  @spec check(Analyzer.verdict(), [Knowledge.category()]) ::
          :ok | {:violation, Analyzer.verdict()}
  def check(:pure, _except), do: :ok
  def check({:conditional, _positions}, _except), do: :ok

  def check({tag, reasons}, except) when tag in [:impure, :unknown] do
    case Enum.reject(reasons, fn {category, _origin, _via} -> category in except end) do
      [] -> :ok
      remaining -> {:violation, verdict(remaining)}
    end
  end

  defp verdict(reasons) do
    if Enum.all?(reasons, fn {category, _origin, _via} -> Knowledge.lost_trail?(category) end) do
      {:unknown, reasons}
    else
      {:impure, reasons}
    end
  end

  @doc """
  Waived classes the function does not actually have.

  A waiver that has outlived the effect it was written for makes the
  annotation say something untrue about the code, so it is worth pointing
  at even though it can only ever make the check more permissive.

      iex> Pure.Annotation.stale([{:io, {IO, :puts, 1}, nil}], [:io, :time])
      [:time]
  """
  @spec stale([Analyzer.reason()], [Knowledge.category()]) :: [Knowledge.category()]
  def stale(effects, except) do
    present = MapSet.new(effects, fn {category, _origin, _via} -> category end)
    Enum.reject(except, &MapSet.member?(present, &1))
  end

  @doc """
  The annotation as it would be written.

      iex> Pure.Annotation.explain(%{except: [], scope: :function, problems: []})
      "@pure"

      iex> Pure.Annotation.explain(%{except: [:time], scope: :module, problems: []})
      "@pure_module except: [:time]"
  """
  @spec explain(t()) :: String.t()
  def explain(%{except: except, scope: scope}) do
    name = if scope == :module, do: "@pure_module", else: "@pure"
    if except == [], do: name, else: "#{name} except: #{inspect(except)}"
  end

  @doc """
  A one-line explanation of what is wrong with an annotation.

      iex> Pure.Annotation.describe_problem({:unknown_effects, [:tyme]})
      "waives :tyme, which is not an effect class"

      iex> Pure.Annotation.describe_problem({:unknown_effects, [:tyme, :aio]})
      "waives :tyme, :aio, which are not effect classes"
  """
  @spec describe_problem(problem()) :: String.t()
  def describe_problem({:unknown_effects, [unknown]}) do
    "waives #{inspect(unknown)}, which is not an effect class"
  end

  def describe_problem({:unknown_effects, unknown}) do
    "waives #{list(unknown)}, which are not effect classes"
  end

  def describe_problem({:widens, widened}) do
    "waives #{list(widened)}, which its module's @pure_module does not"
  end

  def describe_problem({:invalid, false}) do
    "is set to `false`; waive the effect classes it has, or exempt the " <>
      "function with a `# credo:disable-for-next-line Pure.Check.Purity` comment"
  end

  def describe_problem({:invalid, value}) do
    "is set to `#{inspect(value)}`, which is neither `true` nor `except: [...]`"
  end

  @doc """
  How to name an annotation in a message.

      iex> Pure.Annotation.subject({Payments.Core, :fee, 2})
      "@pure on Payments.Core.fee/2"

      iex> Pure.Annotation.subject(Payments.Core)
      "@pure_module on Payments.Core"
  """
  @spec subject(mfa() | module()) :: String.t()
  def subject({module, function, arity}), do: "@pure on #{inspect(module)}.#{function}/#{arity}"
  def subject(module) when is_atom(module), do: "@pure_module on #{inspect(module)}"

  defp list(atoms), do: Enum.map_join(atoms, ", ", &inspect/1)

  @doc """
  The 1-based arities a definition with default arguments produces.

      iex> Pure.Annotation.arities(2, 1)
      [1, 2]
  """
  @spec arities(non_neg_integer(), non_neg_integer()) :: [non_neg_integer()]
  def arities(arity, defaults), do: Enum.to_list((arity - defaults)..arity//1)
end
