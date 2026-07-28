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
  Directories holding the compiled beams of the current Mix project.

  With `deps: true` the dependencies' `ebin` directories come along,
  which is what you want when the analyser should follow calls into
  libraries instead of reporting them as unknown.
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
      other -> {:error, other}
    end
  end

  defp locate(path) when is_binary(path), do: {:ok, String.to_charlist(path)}
end
