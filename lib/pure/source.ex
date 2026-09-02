defmodule Pure.Source do
  @moduledoc """
  Where the annotations are, as opposed to what they mean.

  `Pure.Analyzer` reads `@pure` out of a beam file, which is the whole
  truth about what was compiled but says nothing about where it was
  written. A linter needs the other half: the module, the function and
  the line the annotation sits on, straight from the source.

  Reading the source also fails closed. An annotation on a module that
  was never compiled still exists here, so it can be reported rather than
  quietly disappearing from a run that would otherwise pass.

  What is written in the source and what reaches the beam are not always
  the same thing: a `def` produced by a macro has no annotation to find
  here, so `mix pure --check` stays the way to cover those.
  """

  use Pure

  alias Pure.Annotation

  @pure_module true

  @typedoc "An annotation as written, before anything has been made of its value."
  @type written :: %{value: term(), line: pos_integer()}

  @type function_entry :: %{
          name: atom(),
          arity: arity(),
          line: pos_integer(),
          public?: boolean(),
          annotation: written() | nil
        }

  @type module_entry :: %{
          module: module(),
          line: pos_integer(),
          annotation: written() | nil,
          functions: [function_entry()]
        }

  @definitions [:def, :defp, :defdelegate]

  @doc """
  Every annotated module in an Elixir AST.

  Modules with nothing to say about purity are left out, so a call site
  can tell from an empty list that a file is none of its business.

      iex> {:ok, ast} = Code.string_to_quoted(~s|
      ...>   defmodule Payments.Core do
      ...>     @pure except: [:time]
      ...>     def stamp(x), do: {DateTime.utc_now(), x}
      ...>   end
      ...> |)
      iex> [module] = Pure.Source.annotations(ast)
      iex> module.module
      Payments.Core
      iex> [function] = module.functions
      iex> {function.name, function.arity, function.annotation.value}
      {:stamp, 1, [except: [:time]]}
  """
  @spec annotations(Macro.t()) :: [module_entry()]
  def annotations(ast) do
    ast
    |> modules([], [])
    |> Enum.reverse()
    |> Enum.filter(&annotated?/1)
  end

  defp annotated?(%{annotation: nil, functions: functions}) do
    Enum.any?(functions, &(&1.annotation != nil))
  end

  defp annotated?(_module), do: true

  defp modules({:defmodule, meta, [{:__aliases__, _anno, parts}, body]}, namespace, acc)
       when is_list(parts) do
    path = namespace ++ parts
    statements = statements(body)

    Enum.reduce(statements, [module(path, meta, statements) | acc], &modules(&1, path, &2))
  end

  defp modules({_form, _meta, arguments}, namespace, acc) when is_list(arguments) do
    Enum.reduce(arguments, acc, &modules(&1, namespace, &2))
  end

  defp modules(list, namespace, acc) when is_list(list) do
    Enum.reduce(list, acc, &modules(&1, namespace, &2))
  end

  defp modules({left, right}, namespace, acc) do
    modules(right, namespace, modules(left, namespace, acc))
  end

  defp modules(_leaf, _namespace, acc), do: acc

  defp statements(body) when is_list(body) do
    if Keyword.keyword?(body) do
      case Keyword.get(body, :do) do
        nil -> []
        {:__block__, _meta, statements} -> statements
        statement -> [statement]
      end
    else
      []
    end
  end

  defp statements(_body), do: []

  defp module(path, meta, statements) do
    {annotation, _pending, functions} =
      Enum.reduce(statements, {nil, nil, []}, &statement/2)

    %{
      module: Module.concat(path),
      line: line(meta),
      annotation: annotation,
      functions: Enum.reverse(functions)
    }
  end

  defp statement({:@, meta, [{:pure_module, _anno, [value]}]}, {_annotation, pending, functions}) do
    {written(value, meta), pending, functions}
  end

  defp statement({:@, meta, [{:pure, _anno, [value]}]}, {annotation, _pending, functions}) do
    {annotation, written(value, meta), functions}
  end

  defp statement({kind, meta, [head | _rest]}, {annotation, pending, functions})
       when kind in @definitions do
    case signature(head) do
      nil ->
        {annotation, pending, functions}

      {name, arguments} ->
        {annotation, nil, define(functions, kind, name, arguments, meta, pending)}
    end
  end

  # Anything else between an annotation and the definition it belongs to
  # leaves the annotation standing, the way the compiler does: `@pure`
  # followed by `@doc` still annotates the function underneath both.
  defp statement(_other, acc), do: acc

  defp written(value, meta), do: %{value: value, line: line(meta)}

  defp signature({:when, _meta, [head | _guards]}), do: signature(head)

  defp signature({name, _meta, arguments}) when is_atom(name) and is_list(arguments) do
    {name, arguments}
  end

  defp signature({name, _meta, nil}) when is_atom(name), do: {name, []}
  defp signature(_other), do: nil

  # A default argument compiles to one function per arity it can be
  # called with, and the annotation covers all of them.
  defp define(functions, kind, name, arguments, meta, pending) do
    defaults = Enum.count(arguments, &match?({:\\, _meta, [_argument, _default]}, &1))

    Enum.reduce(Annotation.arities(length(arguments), defaults), functions, fn arity, functions ->
      remember(functions, %{
        name: name,
        arity: arity,
        line: line(meta),
        public?: kind != :defp,
        annotation: pending
      })
    end)
  end

  # Clauses of one function are one function. The annotation can sit above
  # any of them, which is also where the compiler picks it up.
  defp remember(functions, entry) do
    case Enum.find_index(functions, &(&1.name == entry.name and &1.arity == entry.arity)) do
      nil -> [entry | functions]
      _index when entry.annotation == nil -> functions
      index -> List.replace_at(functions, index, entry)
    end
  end

  defp line(meta), do: Keyword.get(meta, :line, 1)
end
