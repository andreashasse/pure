defmodule Pure.Beam do
  @moduledoc """
  The imperative shell: turn modules, directories and `.beam` files into
  abstract forms for `Pure.Analyzer`.

  Both Erlang and Elixir modules work — Elixir's debug info backend hands
  out Erlang abstract format on request, so the analyser only ever sees
  one language, after macro expansion.
  """

  @type failure :: {module() | Path.t(), :no_debug_info | :not_found | term()}

  @doc """
  Load abstract forms for every target.

  A target is a module, a directory (searched recursively for `.beam`
  files) or the path of a single `.beam` file. Returns the forms it could
  read plus the targets it could not, which is normal: modules compiled
  without `debug_info` cannot be analysed at all.
  """
  @spec load([module() | Path.t()]) :: {%{module() => [tuple()]}, [failure()]}
  def load(targets) do
    targets
    |> Enum.flat_map(&expand/1)
    |> Enum.uniq()
    |> Enum.reduce({%{}, []}, fn target, {forms, failures} ->
      case read(target) do
        {:ok, module, module_forms} -> {Map.put(forms, module, module_forms), failures}
        {:error, failure} -> {forms, [failure | failures]}
      end
    end)
    |> then(fn {forms, failures} -> {forms, Enum.reverse(failures)} end)
  end

  @doc """
  Add every protocol the given forms dispatch to, and its implementations.

  A call to `Collectable.into/1` is only as pure as the implementations
  it can reach, so they have to be part of the analysis. The protocol
  module itself comes along because its `-callback` declarations are
  what makes the call recognisable as a dispatch.
  """
  @spec load_implementations({%{module() => [tuple()]}, [failure()]}) ::
          {%{module() => [tuple()]}, [failure()]}
  def load_implementations({forms, failures}) do
    wanted =
      forms
      |> referenced_modules()
      |> Enum.filter(&protocol?/1)
      |> Enum.flat_map(&[&1 | implementations(&1)])
      |> Enum.reject(&Map.has_key?(forms, &1))
      |> Enum.uniq()

    {loaded, more_failures} = load(wanted)
    {Map.merge(loaded, forms), failures ++ more_failures}
  end

  defp referenced_modules(forms) do
    forms |> Map.values() |> remotes(MapSet.new())
  end

  defp remotes({:remote, _anno, {:atom, _, module}, _function}, acc), do: MapSet.put(acc, module)
  defp remotes(list, acc) when is_list(list), do: Enum.reduce(list, acc, &remotes/2)
  defp remotes(tuple, acc) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> remotes(acc)
  defp remotes(_leaf, acc), do: acc

  defp protocol?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__protocol__, 1)
  end

  defp implementations(protocol) do
    case protocol.__protocol__(:impls) do
      {:consolidated, types} -> Enum.map(types, &Module.concat(protocol, &1))
      _not_consolidated -> extract_implementations(protocol)
    end
  end

  defp extract_implementations(protocol) do
    protocol
    |> Protocol.extract_impls(:code.get_path())
    |> Enum.map(&Module.concat(protocol, &1))
  rescue
    _ -> []
  end

  @doc """
  Directories holding the compiled beams of the current Mix project.

  With `deps: true` the dependencies' `ebin` directories come along,
  which is what the `mix pure` task does by default: following calls
  into libraries turns unknowns into real answers.
  """
  @spec build_dirs(keyword()) :: [Path.t()]
  def build_dirs(opts \\ []) do
    if Keyword.get(opts, :deps, false) do
      Mix.Project.build_path() |> Path.join("lib/*/ebin") |> Path.wildcard()
    else
      [Mix.Project.compile_path()]
    end
  end

  defp expand(module) when is_atom(module), do: [module]

  defp expand(path) when is_binary(path) do
    cond do
      File.dir?(path) -> path |> Path.join("**/*.beam") |> Path.wildcard()
      Path.extname(path) == ".beam" -> [path]
      true -> []
    end
  end

  defp read(target) do
    with {:ok, source} <- locate(target),
         {:ok, {module, [abstract_code: abstract]}} <-
           :beam_lib.chunks(source, [:abstract_code]) do
      case abstract do
        {:raw_abstract_v1, forms} -> {:ok, module, forms}
        :no_abstract_code -> {:error, {module, :no_debug_info}}
      end
    else
      {:error, :beam_lib, reason} -> {:error, {target, reason}}
      {:error, reason} -> {:error, {target, reason}}
    end
  end

  defp locate(module) when is_atom(module) do
    case :code.which(module) do
      path when is_list(path) -> {:ok, path}
      :preloaded -> {:error, :no_debug_info}
      :non_existing -> {:error, :not_found}
      :cover_compiled -> covered(module)
      other -> {:error, other}
    end
  end

  defp locate(path) when is_binary(path), do: {:ok, String.to_charlist(path)}

  # Under `mix test --cover` the loaded module has no file of its own,
  # but the beam it was compiled from is still on disk. Called through
  # apply/3 because :cover lives in :tools, which this library does not
  # depend on.
  defp covered(module) do
    with true <- Code.ensure_loaded?(:cover),
         {:file, path} <- apply(:cover, :is_compiled, [module]) do
      {:ok, path}
    else
      _ -> {:error, :not_found}
    end
  end
end
