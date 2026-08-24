defmodule Pure.Analyzer do
  @moduledoc """
  The functional core: Erlang abstract forms in, purity verdicts out.

  Nothing here reads a file or loads a module, so the whole analysis is
  testable from literal forms.

  ## How it works

  1. **Scan.** Every function body is walked for the things that can
     possibly have an effect: calls, fun references, `!` and `receive`.
     Calls keep a *shape* for each argument (`:fun`, `{:param, i}`,
     `{:literal, type}` or `:opaque`) so higher-order arguments and
     dispatch targets can be resolved later.
  2. **Resolve.** Each call becomes either a dependency on another
     analysed function, an effect from `Pure.Knowledge`, or an
     `:unknown` effect. Applying an argument makes the function
     higher-order at that position rather than impure; applying anything
     else the analyser cannot see is a `:higher_order` effect.
  3. **Dispatch.** A call that picks its target at runtime depends on
     every implementation it can reach, so all of them have to be pure
     for it to be pure. Protocols and behaviours are the same thing
     here: a module declaring a `-callback` is dispatched to its
     implementations. A literal at the call site narrows that to the one
     implementation it will actually reach.
  4. **Fixpoint.** Effects flow backwards along the call graph until
     nothing changes. Recursion needs no special case: the least
     fixpoint starts from "no effects" and only grows.

  The result is three-valued on purpose — `:pure`, `{:impure, reasons}`
  and `{:unknown, reasons}` are different answers, and collapsing the
  third into either of the others makes the tool lie.
  """

  use Pure

  alias Pure.{Annotation, Knowledge}

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
          annotation: Annotation.t() | nil,
          exported: boolean()
        }

  # Compiler-generated functions that say nothing about the code as written.
  @generated [{:module_info, 0}, {:module_info, 1}, {:__info__, 1}]

  # Macros compile to `MACRO-name/arity`. They run at compile time, where
  # purity is a different question, so they are left out of reports.
  @macro_prefix "MACRO-"

  # Beyond this a one-line verdict stops being readable; the full list
  # stays in the result for callers that want it.
  @explained_reasons 3

  @doc """
  Analyse a `%{module => abstract_forms}` map.

  Options:

    * `:known` - a `%{mfa => Pure.Knowledge.answer}` map that overrides
      the built-in knowledge base, for libraries it does not cover.
  """
  @pure true
  @spec analyze(%{module() => [tuple()]}, keyword()) :: %{mfa() => result()}
  def analyze(forms_by_module, opts \\ []) do
    known = Keyword.get(opts, :known, %{})

    functions =
      forms_by_module
      |> Enum.flat_map(fn {module, forms} -> scan_module(module, forms) end)
      |> Map.new()

    analyzed = MapSet.new(Map.keys(functions))
    dispatch = dispatch_index(forms_by_module, analyzed)
    context = %{analyzed: analyzed, known: known, dispatch: dispatch}
    hofs = settle_hofs(functions, context)
    resolved = resolve_all(functions, context, hofs)
    effects = settle_effects(resolved)

    Map.new(functions, fn {mfa, scan} ->
      reasons = effects |> Map.fetch!(mfa) |> present_reasons()
      hof_params = resolved |> Map.fetch!(mfa) |> Map.fetch!(:hof_params) |> Enum.sort()

      {mfa,
       %{
         verdict: verdict(reasons, hof_params),
         effects: reasons,
         hof_params: hof_params,
         annotation: scan.annotation,
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

  @doc """
  Whether a function is compiler-generated or compile-time only.

      iex> Pure.Analyzer.generated?({MyApp, :module_info, 0})
      true

      iex> Pure.Analyzer.generated?({MyApp, :total, 1})
      false
  """
  @pure true
  @spec generated?(mfa()) :: boolean()
  def generated?({_module, function, arity}) do
    {function, arity} in @generated or
      String.starts_with?(Atom.to_string(function), @macro_prefix)
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
    module_annotation = module_annotation(forms)
    exported = exports(forms)
    imported = imports(forms)

    for {:function, _anno, name, arity, clauses} <- forms do
      scan = Enum.reduce(clauses, empty_scan(), &scan_clause/2)
      mfa = {module, name, arity}
      public? = MapSet.member?(exported, {name, arity})

      {mfa,
       %{
         scan
         | annotation:
             annotation_for(
               Map.get(annotated, {name, arity}),
               module_annotation,
               public? and not generated?(mfa)
             ),
           exported: public?,
           imports: imported
       }}
    end
  end

  # A module-wide annotation covers the module's public interface: every
  # function someone else can call, and none of the ones the compiler
  # wrote. A function of its own may narrow what the module waives, and
  # anything it adds on top is recorded as a problem rather than granted.
  defp annotation_for(nil, nil, _covered?), do: nil
  defp annotation_for(nil, _module_annotation, false), do: nil

  defp annotation_for(nil, module_annotation, true) do
    Annotation.build(module_annotation, :module)
  end

  defp annotation_for(parsed, nil, _covered?), do: Annotation.build(parsed, :function)

  defp annotation_for(parsed, module_annotation, _covered?) do
    Annotation.build(parsed, :function, within(module_annotation))
  end

  # A module annotation that could not be read constrains nothing; it is
  # reported on its own instead of making every waiver below it look like
  # a widening.
  defp within({:ok, except}), do: except
  defp within({:error, _problem}), do: nil

  # An Erlang `-import(lists, [reverse/1])` turns `reverse(L)` into a
  # local call in the abstract code even though it lands in another
  # module.
  defp imports(forms) do
    for {:attribute, _anno, :import, {module, functions}} <- forms,
        {function, arity} <- functions,
        into: %{},
        do: {{function, arity}, module}
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
        entry <- List.wrap(value),
        parsed = annotation_entry(entry),
        parsed != nil,
        into: %{},
        do: parsed
  end

  defp annotation_entry({function, arity}) when is_atom(function) and is_integer(arity) do
    {{function, arity}, {:ok, []}}
  end

  defp annotation_entry({function, arity, except})
       when is_atom(function) and is_integer(arity) do
    {{function, arity}, Annotation.parse(except: except)}
  end

  defp annotation_entry(_other), do: nil

  defp module_annotation(forms) do
    declared = for {:attribute, _anno, :pure_module, value} <- forms, do: value

    case declared do
      [] -> nil
      [value | _rest] -> value |> module_value() |> Annotation.parse()
    end
  end

  # Elixir persists a module attribute wrapped in a list of its values;
  # an Erlang -pure_module writes the term exactly as given.
  defp module_value([true]), do: true
  defp module_value([[_ | _] = keyword]), do: keyword
  defp module_value(value), do: value

  defp empty_scan do
    %{
      effects: MapSet.new(),
      calls: [],
      hof_params: MapSet.new(),
      annotation: nil,
      exported: false,
      imports: %{}
    }
  end

  defp scan_clause({:clause, _anno, patterns, _guards, body}, scan) do
    context = %{
      params: param_index(patterns),
      funs: bound_funs(body),
      types: bound_types(body)
    }

    walk(body, context, scan)
  end

  # `to_string(%Quiet{})` inlines to `case %Quiet{} do x when is_binary(x)
  # -> x; x -> String.Chars.to_string(x) end`, so the term whose type
  # decides the dispatch reaches the call as a variable. Following that
  # one binding is what keeps a dispatch on a known struct from being
  # answered with a join over every implementation.
  defp bound_types(body), do: collect_types(body, %{})

  defp collect_types({:match, _anno, {:var, _, name}, value}, types) do
    types |> remember_type(name, value) |> then(&collect_types(value, &1))
  end

  defp collect_types({:case, _anno, subject, clauses}, types) do
    clauses
    |> Enum.reduce(types, fn
      {:clause, _anno, [{:var, _, name}], _guards, _body}, types ->
        remember_type(types, name, subject)

      _clause, types ->
        types
    end)
    |> then(&collect_types([subject, clauses], &1))
  end

  defp collect_types(list, types) when is_list(list) do
    Enum.reduce(list, types, &collect_types/2)
  end

  defp collect_types(tuple, types) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> collect_types(types)
  end

  defp collect_types(_leaf, types), do: types

  # A name bound to two different types somewhere in the same clause is
  # not worth guessing about.
  defp remember_type(types, name, value) do
    case literal_type(value) do
      nil -> types
      type -> remember(types, name, type)
    end
  end

  defp remember(types, name, type) do
    case Map.fetch(types, name) do
      :error -> Map.put(types, name, type)
      {:ok, ^type} -> types
      {:ok, _other} -> Map.put(types, name, :conflict)
    end
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

  # `calendar.date_to_string(y, m, d)` names no module, but the function
  # it names is a callback of the `Calendar` behaviour, so the reachable
  # implementations are known even though the module is not.
  defp walk({:call, _anno, {:remote, _, module, {:atom, _, function}}, args}, params, scan) do
    scan
    |> add_callback_call({function, length(args)}, args, params)
    |> deeper([module | args], params)
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

  defp add_callback_call(scan, {f, a}, args, params) do
    %{scan | calls: [{:call, {:callback, f, a}, shapes(args, params)} | scan.calls]}
  end

  defp add_reference(scan, target) do
    %{scan | calls: [{:reference, target, []} | scan.calls]}
  end

  defp shapes(args, context), do: Enum.map(args, &shape(&1, context))

  defp shape({:fun, _, _}, _context), do: :fun
  defp shape({:named_fun, _, _, _}, _context), do: :fun

  defp shape({:var, _, name}, context) do
    case classify_variable(name, context) do
      :opaque -> variable_type(name, context)
      resolved -> resolved
    end
  end

  defp shape(expression, _context) do
    case literal_type(expression) do
      nil -> :opaque
      type -> {:literal, type}
    end
  end

  defp variable_type(name, context) do
    case Map.get(context.types, name) do
      nil -> :opaque
      :conflict -> :opaque
      type -> {:literal, type}
    end
  end

  # Literals matter twice over: a term that cannot be a fun is never
  # applied as one, and its type says which protocol implementation a
  # dispatch on it will reach.
  defp literal_type({:map, _, assocs}), do: struct_or_map(assocs)
  defp literal_type({:map, _, base, assocs}), do: struct_or_map(assocs ++ [base])
  defp literal_type({:integer, _, _}), do: Integer
  defp literal_type({:float, _, _}), do: Float
  defp literal_type({:atom, _, _}), do: Atom
  defp literal_type({:char, _, _}), do: Integer
  defp literal_type({:string, _, _}), do: List
  defp literal_type({:bin, _, _}), do: BitString
  defp literal_type({:tuple, _, _}), do: Tuple
  defp literal_type({:cons, _, _, _}), do: List
  defp literal_type({nil, _}), do: List
  defp literal_type(_other), do: nil

  defp struct_or_map(assocs) do
    Enum.find_value(assocs, Map, fn
      {_assoc, _anno, {:atom, _, :__struct__}, {:atom, _, struct}} -> struct
      {:map, _, nested} -> struct_or_map(nested)
      _other -> false
    end)
  end

  ## Dispatch ---------------------------------------------------------------

  # A protocol is a behaviour whose implementations are separate modules:
  # `Enumerable` declares `-callback reduce/3` and `Enumerable.List`
  # declares `-behaviour(Enumerable)`. So one rule covers both - a call
  # to a module that declares the callback is a dispatch, and the answer
  # is the join over the implementations that are known here.
  #
  # Resolving to the implementations also has to *replace* the call to
  # the protocol module itself, whose body loads the implementation and
  # would drag `:code_loading` into every caller.
  defp dispatch_index(forms_by_module, analyzed) do
    implementers =
      Enum.reduce(forms_by_module, %{}, fn {module, forms}, acc ->
        Enum.reduce(behaviours(forms), acc, fn behaviour, acc ->
          Map.update(acc, behaviour, [module], &[module | &1])
        end)
      end)

    targets =
      for {module, forms} <- forms_by_module,
          {function, arity} <- callbacks(forms),
          into: %{} do
        implementations =
          implementers
          |> Map.get(module, [])
          |> Enum.map(&{&1, function, arity})
          |> Enum.filter(&MapSet.member?(analyzed, &1))
          |> Enum.sort()

        {{module, function, arity}, implementations}
      end

    %{
      targets: targets,
      callbacks: by_callback(targets),
      protocols: protocols(forms_by_module)
    }
  end

  # The same implementations, reachable by callback name alone, for a
  # dispatch that names the function but not the module. If two
  # behaviours happen to declare the same callback, both sets join.
  defp by_callback(targets) do
    targets
    |> Enum.reduce(%{}, fn {{_module, function, arity}, implementations}, acc ->
      Map.update(acc, {function, arity}, implementations, &(implementations ++ &1))
    end)
    |> Map.new(fn {callback, implementations} ->
      {callback, implementations |> Enum.uniq() |> Enum.sort()}
    end)
  end

  # An Elixir protocol picks its implementation from the first argument,
  # so a literal there settles the dispatch on its own. A plain
  # behaviour has no such argument and always joins.
  defp protocols(forms_by_module) do
    for {module, forms} <- forms_by_module,
        Enum.any?(forms, &match?({:function, _, :__protocol__, 1, _}, &1)),
        into: MapSet.new(),
        do: module
  end

  defp behaviours(forms) do
    for {:attribute, _anno, name, behaviour} <- forms,
        name in [:behaviour, :behavior],
        is_atom(behaviour),
        do: behaviour
  end

  defp callbacks(forms) do
    for {:attribute, _anno, :callback, {{function, arity}, _spec}} <- forms,
        do: {function, arity}
  end

  ## Resolving --------------------------------------------------------------

  # A function that only passes its own argument on to another
  # higher-order function is higher-order too, which is only visible once
  # the callee is known to be higher-order. Iterating to a fixpoint costs
  # two passes in practice and keeps `wrap(list, fun)` honest.
  defp settle_hofs(functions, context) do
    initial = Map.new(functions, fn {mfa, scan} -> {mfa, scan.hof_params} end)

    Enum.reduce_while(1..8, initial, fn _round, hofs ->
      next =
        functions
        |> resolve_all(context, hofs)
        |> Map.new(fn {mfa, function} -> {mfa, function.hof_params} end)

      if next == hofs, do: {:halt, hofs}, else: {:cont, next}
    end)
  end

  defp resolve_all(functions, context, hofs) do
    Map.new(functions, fn {mfa, scan} ->
      {mfa, resolve_function(mfa, scan, context, hofs)}
    end)
  end

  defp resolve_function({module, _, _}, scan, context, hofs) do
    initial = %{effects: scan.effects, deps: MapSet.new(), hof_params: scan.hof_params}

    Enum.reduce(scan.calls, initial, fn
      {_kind, {:callback, function, arity}, _shapes}, acc ->
        case Map.get(context.dispatch.callbacks, {function, arity}, []) do
          [] -> %{acc | effects: MapSet.put(acc.effects, {:dynamic_call, nil, nil})}
          targets -> Map.update!(acc, :deps, &Enum.into(targets, &1))
        end

      {kind, target, shapes}, acc ->
        resolve_call(acc, kind, target, shapes, module, scan.imports, context, hofs)
    end)
  end

  defp resolve_call(acc, kind, target, shapes, module, imports, context, hofs) do
    mfa = target_mfa(target, module, imports, context.analyzed)

    case classify(mfa, context) do
      :pure ->
        acc

      {:impure, category} ->
        %{acc | effects: MapSet.put(acc.effects, {category, mfa, nil})}

      {:hof, positions} ->
        check_hof_args(acc, kind, positions, shapes, mfa)

      {:dispatch, targets} ->
        case narrow(targets, mfa, shapes, context) do
          [] -> %{acc | effects: MapSet.put(acc.effects, {:unknown, mfa, nil})}
          targets -> Map.update!(acc, :deps, &Enum.into(targets, &1))
        end

      :analyzed ->
        acc
        |> Map.update!(:deps, &MapSet.put(&1, mfa))
        |> check_hof_args(kind, Map.get(hofs, mfa, []), shapes, mfa)

      :unknown ->
        %{acc | effects: MapSet.put(acc.effects, {:unknown, mfa, nil})}
    end
  end

  defp target_mfa({:remote, m, f, a}, _module, _imports, _analyzed), do: {m, f, a}

  defp target_mfa({:local, f, a}, module, imports, analyzed) do
    cond do
      MapSet.member?(analyzed, {module, f, a}) -> {module, f, a}
      Map.has_key?(imports, {f, a}) -> {Map.fetch!(imports, {f, a}), f, a}
      :erl_internal.bif(f, a) -> {:erlang, f, a}
      true -> {module, f, a}
    end
  end

  defp classify({m, f, a} = mfa, context) do
    with :error <- Map.fetch(context.known, mfa),
         :unknown <- Knowledge.lookup(m, f, a),
         :error <- Map.fetch(context.dispatch.targets, mfa) |> wrap_dispatch() do
      if MapSet.member?(context.analyzed, mfa), do: :analyzed, else: :unknown
    else
      {:ok, answer} -> answer
      answer -> answer
    end
  end

  defp wrap_dispatch({:ok, targets}), do: {:ok, {:dispatch, targets}}
  defp wrap_dispatch(:error), do: :error

  # `for x <- xs, into: %{}` can only reach `Collectable.Map`, so joining
  # over every collectable - `File.Stream` among them - would report it
  # as writing to disk.
  defp narrow(targets, {module, function, arity}, shapes, context) do
    with true <- MapSet.member?(context.dispatch.protocols, module),
         [{:literal, type} | _] <- shapes,
         implementation = {Module.concat(module, type), function, arity},
         true <- MapSet.member?(context.analyzed, implementation) do
      [implementation]
    else
      _ -> targets
    end
  end

  # A bare `&Enum.map/2` supplies no arguments to inspect, so the caller
  # that eventually applies it takes the blame instead.
  defp check_hof_args(acc, :reference, _positions, _shapes, _mfa), do: acc

  defp check_hof_args(acc, :call, positions, shapes, mfa) do
    Enum.reduce(positions, acc, fn position, acc ->
      case Enum.at(shapes, position - 1) do
        :fun -> acc
        {:literal, _type} -> acc
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
      {Knowledge.lost_trail?(category), category, inspect(origin)}
    end)
  end

  defp verdict([], []), do: :pure
  defp verdict([], hof_params), do: {:conditional, hof_params}

  defp verdict(reasons, _hof_params) do
    if Enum.all?(reasons, fn {category, _, _} -> Knowledge.lost_trail?(category) end) do
      {:unknown, reasons}
    else
      {:impure, reasons}
    end
  end
end
