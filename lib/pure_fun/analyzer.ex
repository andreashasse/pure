defmodule PureFun.Analyzer do
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
     analysed function, an effect from `PureFun.Knowledge`, or an
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

  use PureFun

  alias PureFun.{Annotation, Knowledge}

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

  # Beyond this many origins of one class a one-line verdict stops being
  # readable; the full list stays in the result for callers that want it.
  @explained_reasons 3

  # How many origins of one effect class a function passes on to its
  # callers. See keep/2.
  @kept_per_class 20

  @doc """
  Analyse a `%{module => abstract_forms}` map.

  Options:

    * `:known` - a `%{mfa => PureFun.Knowledge.answer}` map that overrides
      the built-in knowledge base, for libraries it does not cover.
    * `:roots` - the modules whose functions the caller wants answers
      for. Everything else in the map is analysed only as far as the
      roots can reach it, which is what keeps a large build affordable.
      Defaults to every module in the map.
  """
  @pure_fun true
  @spec analyze(%{module() => [tuple()]}, keyword()) :: %{mfa() => result()}
  def analyze(forms_by_module, opts \\ []) do
    known = Keyword.get(opts, :known, %{})
    roots = Keyword.get_lazy(opts, :roots, fn -> Map.keys(forms_by_module) end)

    bodies = bodies(forms_by_module)
    analyzed = MapSet.new(Map.keys(bodies))
    dispatch = dispatch_index(forms_by_module, analyzed)
    context = %{analyzed: analyzed, known: known, dispatch: dispatch}
    functions = scan_reachable(roots, forms_by_module, bodies, context)
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

      iex> PureFun.Analyzer.explain(:pure)
      "pure"

      iex> PureFun.Analyzer.explain({:conditional, [2]})
      "pure if the fun given as argument 2 is pure"

      iex> PureFun.Analyzer.explain({:impure, [{:io, {IO, :puts, 1}, nil}]})
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
    "#{tag}: " <> Enum.map_join(group(reasons), "; ", &explain_group/1)
  end

  @doc """
  Reasons grouped by effect class, each origin once.

  The same call reached through two helpers is one thing to fix, not
  two, so an origin keeps only the first callee it came through.

      iex> PureFun.Analyzer.group([
      ...>   {:io, {IO, :puts, 1}, {App, :a, 0}},
      ...>   {:io, {IO, :puts, 1}, {App, :b, 0}},
      ...>   {:time, {DateTime, :utc_now, 0}, nil}
      ...> ])
      [{:io, [{{IO, :puts, 1}, {App, :a, 0}}]}, {:time, [{{DateTime, :utc_now, 0}, nil}]}]
  """
  @spec group([reason()]) :: [{Knowledge.category(), [{mfa() | nil, mfa() | nil}]}]
  def group(reasons) do
    reasons
    |> Enum.uniq_by(fn {category, origin, _via} -> {category, origin} end)
    |> Enum.chunk_by(fn {category, _origin, _via} -> category end)
    |> Enum.map(fn [{category, _, _} | _] = chunk ->
      {category, Enum.map(chunk, fn {_category, origin, via} -> {origin, via} end)}
    end)
  end

  @doc """
  Origins as a list, naming a module once for a run of calls into it.

      iex> PureFun.Analyzer.list_origins([{Ecto.Changeset, :cast, 3}, {Ecto.Changeset, :cast, 4}, {IO, :puts, 1}])
      "Ecto.Changeset.cast/3, cast/4, IO.puts/1"
  """
  @spec list_origins([mfa() | nil]) :: String.t()
  def list_origins(origins) do
    origins
    |> Enum.reject(&is_nil/1)
    |> Enum.chunk_by(fn {module, _function, _arity} -> module end)
    |> Enum.map_join(", ", fn [{module, function, arity} | rest] ->
      Enum.map_join([{function, arity} | Enum.map(rest, fn {_m, f, a} -> {f, a} end)], ", ", fn
        {^function, ^arity} -> "#{name(module)}.#{function}/#{arity}"
        {f, a} -> "#{f}/#{a}"
      end)
    end)
  end

  @doc """
  Whether a function is compiler-generated or compile-time only.

      iex> PureFun.Analyzer.generated?({MyApp, :module_info, 0})
      true

      iex> PureFun.Analyzer.generated?({MyApp, :total, 1})
      false
  """
  @pure_fun true
  @spec generated?(mfa()) :: boolean()
  def generated?({_module, function, arity}) do
    {function, arity} in @generated or
      String.starts_with?(Atom.to_string(function), @macro_prefix)
  end

  defp explain_group({category, [{origin, via}]}) do
    [Knowledge.describe(category), format_mfa(origin), format_via(via, origin)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp explain_group({category, origins}) do
    {shown, rest} = origins |> Enum.map(&elem(&1, 0)) |> Enum.split(@explained_reasons)
    more = if rest == [], do: "", else: " and #{length(rest)} more"
    itself = if nil in shown, do: "directly, ", else: ""

    "#{Knowledge.describe(category)} (#{itself}#{list_origins(shown)}#{more})"
  end

  defp format_mfa(nil), do: ""
  defp format_mfa({m, f, a}), do: "(#{name(m)}.#{f}/#{a})"

  defp format_via(nil, _origin), do: ""
  defp format_via(same, same), do: ""
  defp format_via({m, f, a}, _origin), do: "via #{name(m)}.#{f}/#{a}"

  defp name(module) when is_atom(module), do: inspect(module)

  ## Scanning ---------------------------------------------------------------

  defp bodies(forms_by_module) do
    for {module, forms} <- forms_by_module,
        {:function, _anno, name, arity, clauses} <- forms,
        into: %{},
        do: {{module, name, arity}, clauses}
  end

  # Only what the roots can reach is scanned. A dependency is mostly code
  # the project never calls, and every function left out here is one the
  # fixpoint below never has to settle.
  defp scan_reachable(roots, forms_by_module, bodies, context) do
    roots = MapSet.new(roots)

    modules =
      for {module, forms} <- forms_by_module, into: %{}, do: {module, module_facts(forms)}

    bodies
    |> Map.keys()
    |> Enum.filter(fn {module, _name, _arity} -> MapSet.member?(roots, module) end)
    |> Enum.sort()
    |> reach(bodies, modules, context, %{})
  end

  defp reach([], _bodies, _modules, _context, scanned), do: scanned

  defp reach([mfa | rest], bodies, modules, context, scanned) when is_map_key(scanned, mfa) do
    reach(rest, bodies, modules, context, scanned)
  end

  defp reach([{module, _name, _arity} = mfa | rest], bodies, modules, context, scanned) do
    scan = scan_function(mfa, Map.fetch!(bodies, mfa), Map.fetch!(modules, module))
    next = successors(mfa, scan, context) ++ rest

    reach(next, bodies, modules, context, Map.put(scanned, mfa, scan))
  end

  # Every analysed function a call can land on, whatever the arguments
  # turn out to narrow it to later.
  defp successors({module, _name, _arity}, scan, context) do
    Enum.flat_map(scan.calls, fn
      {_kind, {:callback, function, arity}, _shapes} ->
        Map.get(context.dispatch.callbacks, {function, arity}, [])

      {_kind, target, _shapes} ->
        mfa = target_mfa(target, module, scan.imports, context.analyzed)

        case classify(mfa, context) do
          {:dispatch, targets} -> targets
          :analyzed -> [mfa]
          _answer -> []
        end
    end)
  end

  defp module_facts(forms) do
    %{
      annotated: annotations(forms),
      annotation: module_annotation(forms),
      exported: exports(forms),
      imported: imports(forms)
    }
  end

  defp scan_function({_module, name, arity} = mfa, clauses, facts) do
    scan = Enum.reduce(clauses, empty_scan(), &scan_clause/2)
    public? = MapSet.member?(facts.exported, {name, arity})

    %{
      scan
      | annotation:
          annotation_for(
            Map.get(facts.annotated, {name, arity}),
            facts.annotation,
            public? and not generated?(mfa)
          ),
        exported: public?,
        imports: facts.imported
    }
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
        name in [:pure_fun, :pure_fun_annotated],
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
    declared = for {:attribute, _anno, :pure_fun_module, value} <- forms, do: value

    case declared do
      [] -> nil
      [value | _rest] -> value |> module_value() |> Annotation.parse()
    end
  end

  # Elixir persists a module attribute wrapped in a list of its values;
  # an Erlang -pure_fun_module writes the term exactly as given.
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

  # Effects flow backwards along the call graph. Every function in a
  # cycle reaches every other one, so each strongly connected component
  # is settled once, as a whole, after everything it calls. That visits
  # each call edge once, where iterating until nothing changes copied a
  # callee's whole effect set on every revisit and took hours on a large
  # build.
  #
  # Effects are kept as `{category, origin}` while they flow, with an
  # origin of `nil` replaced by the function that has the effect. Which
  # callee an effect came in through is worked out afterwards, per
  # function, from the direct callees alone.
  defp settle_effects(resolved) do
    own = Map.new(resolved, fn {mfa, function} -> {mfa, absolute(function.effects, mfa)} end)

    reachable =
      resolved
      |> components()
      |> Enum.reduce(%{}, &settle_component(&1, own, resolved, &2))

    Map.new(resolved, fn {mfa, function} ->
      {mfa, reasons(mfa, function, own, reachable)}
    end)
  end

  defp absolute(effects, mfa) do
    MapSet.new(effects, fn {category, origin, _via} -> {category, origin || mfa} end)
  end

  defp settle_component(members, own, resolved, reachable) do
    inside = MapSet.new(members)

    mine = members |> Enum.map(&Map.fetch!(own, &1)) |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    inherited =
      for member <- members,
          dep <- Map.fetch!(resolved, member).deps,
          not MapSet.member?(inside, dep),
          effect <- Map.get(reachable, dep, []),
          into: MapSet.new(),
          do: effect

    effects = keep(mine, inherited)
    Enum.reduce(members, reachable, &Map.put(&2, &1, effects))
  end

  # A function deep in a dependency can reach hundreds of unknowns, and
  # carrying every one of them into every caller is what made large
  # builds slow. A function's own effects are always kept; beyond those,
  # each class keeps its first @kept_per_class origins. The class itself
  # is never lost, and the class is what an annotation is checked on.
  defp keep(mine, inherited) do
    counts = Enum.frequencies_by(mine, fn {category, _origin} -> category end)

    inherited
    |> Enum.reject(&MapSet.member?(mine, &1))
    |> Enum.sort()
    |> Enum.reduce({mine, counts}, fn {category, _origin} = effect, {kept, counts} ->
      if Map.get(counts, category, 0) < @kept_per_class do
        {MapSet.put(kept, effect), Map.update(counts, category, 1, &(&1 + 1))}
      else
        {kept, counts}
      end
    end)
    |> elem(0)
  end

  # An effect a function has itself makes the same effect arriving
  # through a callee redundant noise, so only the rest get a `via`: the
  # first direct callee that reaches it.
  defp reasons(mfa, function, own, reachable) do
    mine = Map.fetch!(own, mfa)
    callees = function.deps |> MapSet.delete(mfa) |> Enum.sort()

    inherited =
      for {category, origin} = effect <- Map.fetch!(reachable, mfa),
          not MapSet.member?(mine, effect),
          do: {category, origin, Enum.find(callees, &reaches?(reachable, &1, effect))}

    MapSet.to_list(function.effects) ++ inherited
  end

  defp reaches?(reachable, callee, effect) do
    reachable |> Map.get(callee, MapSet.new()) |> MapSet.member?(effect)
  end

  # Tarjan's algorithm. Components come out callees first, which is the
  # order they have to be settled in.
  defp components(resolved) do
    initial = %{index: %{}, low: %{}, stack: [], on_stack: MapSet.new(), components: []}

    resolved
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(initial, fn mfa, state ->
      if is_map_key(state.index, mfa), do: state, else: connect(mfa, resolved, state)
    end)
    |> Map.fetch!(:components)
    |> Enum.reverse()
  end

  defp connect(mfa, resolved, state) do
    number = map_size(state.index)

    state = %{
      state
      | index: Map.put(state.index, mfa, number),
        low: Map.put(state.low, mfa, number),
        stack: [mfa | state.stack],
        on_stack: MapSet.put(state.on_stack, mfa)
    }

    state =
      resolved
      |> Map.fetch!(mfa)
      |> Map.fetch!(:deps)
      |> Enum.filter(&is_map_key(resolved, &1))
      |> Enum.reduce(state, fn dep, state ->
        cond do
          not is_map_key(state.index, dep) ->
            state = connect(dep, resolved, state)
            lower(state, mfa, Map.fetch!(state.low, dep))

          MapSet.member?(state.on_stack, dep) ->
            lower(state, mfa, Map.fetch!(state.index, dep))

          true ->
            state
        end
      end)

    if Map.fetch!(state.low, mfa) == Map.fetch!(state.index, mfa) do
      pop_component(mfa, state)
    else
      state
    end
  end

  defp lower(state, mfa, candidate) do
    %{state | low: Map.update!(state.low, mfa, &min(&1, candidate))}
  end

  defp pop_component(root, state) do
    {members, [^root | stack]} = Enum.split_while(state.stack, &(&1 != root))
    members = [root | members]

    %{
      state
      | stack: stack,
        on_stack: Enum.reduce(members, state.on_stack, &MapSet.delete(&2, &1)),
        components: [members | state.components]
    }
  end

  ## Verdicts ---------------------------------------------------------------

  defp present_reasons(effects) do
    Enum.sort_by(effects, fn {category, origin, _via} ->
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
