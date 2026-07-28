defmodule Pure.Analyzer do
  @moduledoc """
  The functional core: Erlang abstract forms in, purity verdicts out.

  Nothing here reads a file or loads a module, so the whole analysis is
  testable from literal forms.

  ## How it works

  1. **Scan.** Every function body is walked for the things that can
     possibly have an effect: calls, fun references, `!` and `receive`.
     Calls keep a *shape* for each argument (`:fun`, `{:param, i}` or
     `:opaque`) so higher-order arguments can be resolved later.
  2. **Resolve.** Each call becomes either a dependency on another
     analysed function, an effect from `Pure.Knowledge`, or an
     `:unknown` effect. Applying an argument makes the function
     higher-order at that position rather than impure; applying anything
     else the analyser cannot see is a `:higher_order` effect.
  3. **Fixpoint.** Effects flow backwards along the call graph until
     nothing changes. Recursion needs no special case: the least
     fixpoint starts from "no effects" and only grows.

  The result is three-valued on purpose — `:pure`, `{:impure, reasons}`
  and `{:unknown, reasons}` are different answers, and collapsing the
  third into either of the others makes the tool lie.
  """

  alias Pure.Knowledge

  @typedoc """
  Why a function is not pure.

  `via` is the direct callee the effect came in through, `nil` when the
  function has the effect itself.
  """
  @type reason :: {Knowledge.category(), mfa() | nil, via :: mfa() | nil}

  @type verdict ::
          :pure
          | {:conditional, [pos_integer()]}
          | {:impure, [reason()]}
          | {:unknown, [reason()]}

  @type result :: %{
          verdict: verdict(),
          effects: [reason()],
          hof_params: [pos_integer()],
          annotated: boolean(),
          exported: boolean()
        }

  # Losing the trail is not the same as finding an effect: a dynamic
  # apply or an unresolvable fun means "cannot tell", and saying so is
  # more useful than a confident wrong answer in either direction.
  @lost_trail [:unknown, :higher_order, :dynamic_call]

  # Beyond this a one-line verdict stops being readable; the full list
  # stays in the result for callers that want it.
  @explained_reasons 3

  @doc """
  Analyse a `%{module => abstract_forms}` map.

  Options:

    * `:known` - a `%{mfa => Pure.Knowledge.answer}` map that overrides
      the built-in knowledge base, for libraries it does not cover.
  """
  @spec analyze(%{module() => [tuple()]}, keyword()) :: %{mfa() => result()}
  def analyze(forms_by_module, opts \\ []) do
    known = Keyword.get(opts, :known, %{})

    functions =
      forms_by_module
      |> Enum.flat_map(fn {module, forms} -> scan_module(module, forms) end)
      |> Map.new()

    analyzed = MapSet.new(Map.keys(functions))
    hofs = settle_hofs(functions, analyzed, known)
    resolved = resolve_all(functions, analyzed, hofs, known)
    effects = settle_effects(resolved)

    Map.new(functions, fn {mfa, scan} ->
      reasons = effects |> Map.fetch!(mfa) |> present_reasons()
      hof_params = resolved |> Map.fetch!(mfa) |> Map.fetch!(:hof_params) |> Enum.sort()

      {mfa,
       %{
         verdict: verdict(reasons, hof_params),
         effects: reasons,
         hof_params: hof_params,
         annotated: scan.annotated,
         exported: scan.exported
       }}
    end)
  end

  @doc """
  A one-line explanation of a verdict.

      iex> Pure.Analyzer.explain(:pure)
      "pure"

      iex> Pure.Analyzer.explain({:conditional, [2]})
      "pure if the fun given as argument 2 is pure"

      iex> Pure.Analyzer.explain({:impure, [{:io, {IO, :puts, 1}, nil}]})
      "impure: performs I/O (IO.puts/1)"
  """
  @spec explain(verdict()) :: String.t()
  def explain(:pure), do: "pure"

  def explain({:conditional, positions}) do
    "pure if the fun#{if length(positions) > 1, do: "s"} given as argument " <>
      Enum.map_join(positions, " and ", &to_string/1) <>
      " #{if length(positions) > 1, do: "are", else: "is"} pure"
  end

  def explain({tag, reasons}) when tag in [:impure, :unknown] do
    {shown, rest} = Enum.split(reasons, @explained_reasons)

    "#{tag}: " <>
      Enum.map_join(shown, ", ", &explain_reason/1) <>
      if rest == [], do: "", else: " (and #{length(rest)} more)"
  end

  defp explain_reason({category, mfa, via}) do
    [Knowledge.describe(category), format_mfa(mfa), format_via(via, mfa)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp format_mfa(nil), do: ""
  defp format_mfa({m, f, a}), do: "(#{name(m)}.#{f}/#{a})"

  defp format_via(nil, _origin), do: ""
  defp format_via(same, same), do: ""
  defp format_via({m, f, a}, _origin), do: "via #{name(m)}.#{f}/#{a}"

  defp name(module) when is_atom(module), do: inspect(module)

  ## Scanning ---------------------------------------------------------------

  defp scan_module(module, forms) do
    annotated = annotations(forms)
    exported = exports(forms)

    for {:function, _anno, name, arity, clauses} <- forms do
      scan = Enum.reduce(clauses, empty_scan(), &scan_clause/2)

      {{module, name, arity},
       %{
         scan
         | annotated: MapSet.member?(annotated, {name, arity}),
           exported: MapSet.member?(exported, {name, arity})
       }}
    end
  end

  defp exports(forms) do
    for {:attribute, _anno, :export, exported} <- forms,
        {function, arity} <- exported,
        into: MapSet.new(),
        do: {function, arity}
  end

  defp annotations(forms) do
    for {:attribute, _anno, name, value} <- forms,
        name in [:pure, :pure_annotated],
        {function, arity} <- List.wrap(value),
        is_atom(function) and is_integer(arity),
        into: MapSet.new() do
      {function, arity}
    end
  end

  defp empty_scan do
    %{
      effects: MapSet.new(),
      calls: [],
      hof_params: MapSet.new(),
      annotated: false,
      exported: false
    }
  end

  defp scan_clause({:clause, _anno, patterns, _guards, body}, scan) do
    walk(body, %{params: param_index(patterns), funs: bound_funs(body)}, scan)
  end

  # `with/else`, `try` and comprehensions compile to a fun bound to a
  # generated variable and applied a few lines later. Variables are
  # single-assignment inside a clause, so collecting every `Var = fun`
  # up front is enough to recognise those applications as resolved - the
  # fun's own body is walked anyway.
  defp bound_funs(body) do
    collect(body, MapSet.new())
  end

  defp collect({:match, _anno, pattern, value}, funs) do
    funs =
      cond do
        fun_expression?(value) -> bind(pattern, funs)
        fun_source?(value) -> bind(pattern, funs)
        true -> funs
      end

    collect(value, funs)
  end

  defp collect(list, funs) when is_list(list), do: Enum.reduce(list, funs, &collect/2)

  defp collect(tuple, funs) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> collect(funs)
  end

  defp collect(_leaf, funs), do: funs

  defp fun_expression?({:fun, _, _}), do: true
  defp fun_expression?({:named_fun, _, _, _}), do: true
  defp fun_expression?(_), do: false

  # `for ... into: %{}` destructures a collector fun out of
  # `Collectable.into/1` and applies it per element. The fun belongs to
  # the collectable's protocol implementation, which the analyser
  # assumes is pure - the same assumption it already makes for
  # `Enumerable`.
  defp fun_source?({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args}) do
    {m, f, length(args)} in [{Collectable, :into, 1}]
  end

  defp fun_source?(_), do: false

  defp bind({:var, _, name}, funs), do: MapSet.put(funs, name)
  defp bind(list, funs) when is_list(list), do: Enum.reduce(list, funs, &bind/2)

  defp bind(tuple, funs) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> bind(funs)
  end

  defp bind(_leaf, funs), do: funs

  defp param_index(patterns) do
    patterns
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn
      {{:var, _, name}, position}, index -> Map.put(index, name, position)
      {_pattern, _position}, index -> index
    end)
  end

  defp walk({:call, _anno, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args}, params, scan) do
    scan
    |> add_call({m, f, length(args)}, args, params)
    |> deeper(args, params)
  end

  defp walk({:call, _anno, {:remote, _, m, f}, args}, params, scan) do
    scan |> add_effect(:dynamic_call) |> deeper([m, f | args], params)
  end

  defp walk({:call, _anno, {:atom, _, f}, args}, params, scan) do
    scan
    |> add_local_call({f, length(args)}, args, params)
    |> deeper(args, params)
  end

  defp walk({:call, _anno, {:var, _, name}, args}, params, scan) do
    scan
    |> apply_variable(name, params)
    |> deeper(args, params)
  end

  # `(fn x -> x end).(1)`, which is also what inlined functions such as
  # `Kernel.then/2` leave behind. The body is walked like any other, so
  # nothing is lost.
  defp walk({:call, _anno, fun, args}, params, scan) when elem(fun, 0) in [:fun, :named_fun] do
    deeper(scan, [fun | args], params)
  end

  defp walk({:call, _anno, fun, args}, params, scan) do
    scan |> add_effect(:higher_order) |> deeper([fun | args], params)
  end

  defp walk({:fun, _anno, {:function, f, a}}, _params, scan) when is_atom(f) and is_integer(a) do
    add_reference(scan, {:local, f, a})
  end

  defp walk({:fun, _anno, {:function, {:atom, _, m}, {:atom, _, f}, {:integer, _, a}}}, _p, scan) do
    add_reference(scan, {:remote, m, f, a})
  end

  defp walk({:fun, _anno, {:function, m, f, a}}, params, scan) do
    scan |> add_effect(:dynamic_call) |> deeper([m, f, a], params)
  end

  defp walk({:op, _anno, :!, left, right}, params, scan) do
    scan |> add_effect(:message) |> deeper([left, right], params)
  end

  defp walk({:receive, _anno, clauses}, params, scan) do
    scan |> add_effect(:message_receive) |> deeper(clauses, params)
  end

  defp walk({:receive, _anno, clauses, timeout, after_body}, params, scan) do
    scan |> add_effect(:message_receive) |> deeper([clauses, timeout, after_body], params)
  end

  defp walk(list, params, scan) when is_list(list) do
    Enum.reduce(list, scan, &walk(&1, params, &2))
  end

  defp walk(tuple, params, scan) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> walk(params, scan)
  end

  defp walk(_leaf, _params, scan), do: scan

  defp deeper(scan, node, params), do: walk(node, params, scan)

  defp apply_variable(scan, name, context) do
    case classify_variable(name, context) do
      :fun -> scan
      {:param, position} -> %{scan | hof_params: MapSet.put(scan.hof_params, position)}
      :opaque -> add_effect(scan, :higher_order)
    end
  end

  defp classify_variable(name, context) do
    cond do
      MapSet.member?(context.funs, name) -> :fun
      Map.has_key?(context.params, name) -> {:param, Map.fetch!(context.params, name)}
      true -> :opaque
    end
  end

  defp add_effect(scan, category) do
    %{scan | effects: MapSet.put(scan.effects, {category, nil, nil})}
  end

  defp add_call(scan, {m, f, a}, args, params) do
    %{scan | calls: [{:call, {:remote, m, f, a}, shapes(args, params)} | scan.calls]}
  end

  defp add_local_call(scan, {f, a}, args, params) do
    %{scan | calls: [{:call, {:local, f, a}, shapes(args, params)} | scan.calls]}
  end

  defp add_reference(scan, target) do
    %{scan | calls: [{:reference, target, []} | scan.calls]}
  end

  defp shapes(args, context), do: Enum.map(args, &shape(&1, context))

  defp shape({:fun, _, _}, _context), do: :fun
  defp shape({:named_fun, _, _, _}, _context), do: :fun
  defp shape({:var, _, name}, context), do: classify_variable(name, context)

  # Several higher-order functions take a non-fun in the same position,
  # such as `Enum.with_index(list, 1)`. A term that cannot be a fun is
  # never applied as one.
  defp shape({literal, _, _}, _context)
       when literal in [:integer, :float, :atom, :char, :string, :bin, :cons, :tuple, :map],
       do: :literal

  defp shape({:cons, _, _, _}, _context), do: :literal
  defp shape({nil, _}, _context), do: :literal
  defp shape(_other, _context), do: :opaque

  ## Resolving --------------------------------------------------------------

  # A function that only passes its own argument on to another
  # higher-order function is higher-order too, which is only visible once
  # the callee is known to be higher-order. Iterating to a fixpoint costs
  # two passes in practice and keeps `wrap(list, fun)` honest.
  defp settle_hofs(functions, analyzed, known) do
    initial = Map.new(functions, fn {mfa, scan} -> {mfa, scan.hof_params} end)

    Enum.reduce_while(1..8, initial, fn _round, hofs ->
      next =
        functions
        |> resolve_all(analyzed, hofs, known)
        |> Map.new(fn {mfa, function} -> {mfa, function.hof_params} end)

      if next == hofs, do: {:halt, hofs}, else: {:cont, next}
    end)
  end

  defp resolve_all(functions, analyzed, hofs, known) do
    Map.new(functions, fn {mfa, scan} ->
      {mfa, resolve_function(mfa, scan, analyzed, hofs, known)}
    end)
  end

  defp resolve_function({module, _, _}, scan, analyzed, hofs, known) do
    initial = %{effects: scan.effects, deps: MapSet.new(), hof_params: scan.hof_params}

    Enum.reduce(scan.calls, initial, fn {kind, target, shapes}, acc ->
      mfa = target_mfa(target, module, analyzed)

      case classify(mfa, analyzed, known) do
        :pure ->
          acc

        {:impure, category} ->
          %{acc | effects: MapSet.put(acc.effects, {category, mfa, nil})}

        {:hof, positions} ->
          check_hof_args(acc, kind, positions, shapes, mfa)

        :analyzed ->
          acc
          |> Map.update!(:deps, &MapSet.put(&1, mfa))
          |> check_hof_args(kind, Map.get(hofs, mfa, []), shapes, mfa)

        :unknown ->
          %{acc | effects: MapSet.put(acc.effects, {:unknown, mfa, nil})}
      end
    end)
  end

  defp target_mfa({:remote, m, f, a}, _module, _analyzed), do: {m, f, a}

  defp target_mfa({:local, f, a}, module, analyzed) do
    cond do
      MapSet.member?(analyzed, {module, f, a}) -> {module, f, a}
      :erl_internal.bif(f, a) -> {:erlang, f, a}
      true -> {module, f, a}
    end
  end

  defp classify({m, f, a} = mfa, analyzed, known) do
    with :error <- Map.fetch(known, mfa),
         :unknown <- Knowledge.lookup(m, f, a) do
      if MapSet.member?(analyzed, mfa), do: :analyzed, else: :unknown
    else
      {:ok, answer} -> answer
      answer -> answer
    end
  end

  # A bare `&Enum.map/2` supplies no arguments to inspect, so the caller
  # that eventually applies it takes the blame instead.
  defp check_hof_args(acc, :reference, _positions, _shapes, _mfa), do: acc

  defp check_hof_args(acc, :call, positions, shapes, mfa) do
    Enum.reduce(positions, acc, fn position, acc ->
      case Enum.at(shapes, position - 1) do
        :fun -> acc
        :literal -> acc
        {:param, i} -> %{acc | hof_params: MapSet.put(acc.hof_params, i)}
        _opaque_or_missing -> %{acc | effects: MapSet.put(acc.effects, {:higher_order, mfa, nil})}
      end
    end)
  end

  ## Fixpoint ---------------------------------------------------------------

  defp settle_effects(resolved) do
    callers =
      Enum.reduce(resolved, %{}, fn {mfa, function}, callers ->
        Enum.reduce(function.deps, callers, fn dep, callers ->
          Map.update(callers, dep, [mfa], &[mfa | &1])
        end)
      end)

    effects = Map.new(resolved, fn {mfa, function} -> {mfa, function.effects} end)
    propagate(:queue.from_list(Map.keys(resolved)), effects, resolved, callers)
  end

  defp propagate(queue, effects, resolved, callers) do
    case :queue.out(queue) do
      {:empty, _} ->
        effects

      {{:value, mfa}, queue} ->
        current = Map.fetch!(effects, mfa)

        merged =
          Enum.reduce(resolved[mfa].deps, current, fn dep, acc ->
            MapSet.union(acc, inherited(effects, dep))
          end)

        if MapSet.equal?(merged, current) do
          propagate(queue, effects, resolved, callers)
        else
          queue = Enum.reduce(Map.get(callers, mfa, []), queue, &:queue.in(&1, &2))
          propagate(queue, Map.put(effects, mfa, merged), resolved, callers)
        end
    end
  end

  defp inherited(effects, dep) do
    effects
    |> Map.get(dep, MapSet.new())
    |> MapSet.new(fn {category, origin, _via} -> {category, origin || dep, dep} end)
  end

  ## Verdicts ---------------------------------------------------------------

  # An effect the function has itself makes the same effect arriving
  # through a callee redundant noise.
  defp present_reasons(effects) do
    direct = for {category, origin, nil} <- effects, into: MapSet.new(), do: {category, origin}

    effects
    |> Enum.reject(fn {category, origin, via} ->
      via != nil and MapSet.member?(direct, {category, origin})
    end)
    |> Enum.sort_by(fn {category, origin, _via} ->
      {category in @lost_trail, category, inspect(origin)}
    end)
  end

  defp verdict([], []), do: :pure
  defp verdict([], hof_params), do: {:conditional, hof_params}

  defp verdict(reasons, _hof_params) do
    if Enum.all?(reasons, fn {category, _, _} -> category in @lost_trail end) do
      {:unknown, reasons}
    else
      {:impure, reasons}
    end
  end
end
