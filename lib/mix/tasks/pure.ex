defmodule Mix.Tasks.Pure do
  @shortdoc "Reports which functions are pure"

  @moduledoc """
  Reports which functions in the project have no side effects.

  Calls into dependencies are followed by default, so a function that
  reaches an effect through a library is reported as impure rather than
  unknown.

      mix pure                     # summary for every module in the project
      mix pure MyApp.Core          # every function in one module
      mix pure MyApp.Core.total/1  # one function, with the reasons
      mix pure --check             # fail if an annotation is not kept

  ## Options

    * `--check` - exit non-zero if an annotation is not kept: a `@pure`
      function that reaches an effect it did not waive, or an annotation
      that is wrong in itself. Waivers nothing needs any more are
      reported without failing anything. This is the CI mode, and
      `Pure.Check.Purity` is the same thing as a Credo check.
    * `--all` - list pure functions too, not just the interesting ones.
    * `--no-deps` - do not follow calls into dependencies. Faster, at
      the cost of reporting every call into a library as unknown.
    * `--unknown` - list functions whose purity could not be determined.
    * `--private` - include private functions.

  ## Configuration

  Functions the knowledge base does not cover can be declared in
  `mix.exs`:

      def project do
        [
          pure: [
            known: %{
              {MyLib.Cache, :get, 1} => {:impure, :ets},
              {MyLib.Fold, :run, 2} => {:hof, [2]}
            }
          ]
        ]
      end
  """

  use Mix.Task

  alias Pure.{Analyzer, Annotation}

  @switches [check: :boolean, all: :boolean, deps: :boolean, unknown: :boolean, private: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, filters} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("compile", [])

    config = Keyword.get(Mix.Project.config(), :pure, [])

    analysis =
      Pure.analyze(
        paths: Pure.Beam.build_dirs(deps: Keyword.get(opts, :deps, true)),
        known: Keyword.get(config, :known, %{})
      )

    warn_skipped(analysis.skipped)

    if opts[:check] do
      check(analysis)
    else
      analysis.results
      |> interesting(opts, Enum.map(filters, &parse_filter/1))
      |> report(opts)
    end
  end

  ## Reporting --------------------------------------------------------------

  defp report([], _opts) do
    Mix.shell().info("No matching functions.")
  end

  defp report(results, opts) do
    results
    |> Enum.group_by(fn {{module, _, _}, _} -> module end)
    |> Enum.sort_by(fn {module, _} -> inspect(module) end)
    |> Enum.each(fn {module, functions} -> report_module(module, functions, opts) end)

    summarize(results)
  end

  defp report_module(module, functions, opts) do
    Mix.shell().info("\n" <> paint(inspect(module), IO.ANSI.bright()))

    functions
    |> Enum.sort_by(fn {{_, f, a}, _} -> {f, a} end)
    |> Enum.each(fn {{_, f, a}, result} ->
      name = String.pad_trailing("#{f}/#{a}", 32)

      annotation =
        if result.annotation, do: " " <> Annotation.explain(result.annotation), else: ""

      Mix.shell().info(
        "  " <> name <> colorize(result.verdict, Analyzer.explain(result.verdict) <> annotation)
      )

      if opts[:all] || verdict_tag(result.verdict) != :pure do
        Enum.each(details(result), &Mix.shell().info("      " <> &1))
      end
    end)
  end

  # The one-liner already names the first reason; the rest are only
  # worth printing when a function has several.
  defp details(%{effects: effects}) when length(effects) > 1 do
    Enum.map(effects, fn {category, mfa, _via} ->
      "- #{Pure.Knowledge.describe(category)}#{if mfa, do: " (#{format(mfa)})", else: ""}"
    end)
  end

  defp details(_result), do: []

  defp summarize(results) do
    counts = Enum.frequencies_by(results, fn {_, result} -> verdict_tag(result.verdict) end)

    line =
      [:pure, :conditional, :impure, :unknown]
      |> Enum.map(&"#{Map.get(counts, &1, 0)} #{&1}")
      |> Enum.join(", ")

    total = length(results)
    Mix.shell().info("\n" <> line <> " (#{total} function#{if total == 1, do: "", else: "s"})")
  end

  ## Check mode -------------------------------------------------------------

  defp check(analysis) do
    violations = Pure.violations(analysis)
    problems = Pure.annotation_problems(analysis)

    # A waiver nothing needs any more only ever makes the check more
    # permissive, so it is said out loud and then let through.
    Enum.each(Pure.stale_waivers(analysis), fn {mfa, stale} ->
      Mix.shell().info("#{format(mfa)} waives #{inspect(stale)}, which it does not do")
    end)

    Enum.each(problems, fn {subject, problem} ->
      Mix.shell().error("#{Annotation.subject(subject)} #{Annotation.describe_problem(problem)}")
    end)

    Enum.each(violations, fn {mfa, verdict} ->
      Mix.shell().error("#{format(mfa)} is annotated @pure but is #{Analyzer.explain(verdict)}")
    end)

    failures = length(violations) + length(problems)

    if failures == 0 do
      annotated = Enum.count(analysis.results, fn {_mfa, result} -> result.annotation end)
      Mix.shell().info("All #{annotated} annotated functions are pure.")
    else
      Mix.raise("#{failures} annotation(s) are not kept")
    end
  end

  ## Filtering --------------------------------------------------------------

  defp interesting(results, opts, filters) do
    results
    |> Enum.reject(fn {mfa, _} -> Pure.generated?(mfa) end)
    |> Enum.filter(fn {_, result} -> result.exported || opts[:private] end)
    |> Enum.filter(fn {mfa, _} -> matches?(mfa, filters) end)
    |> Enum.filter(fn {_, result} -> show?(result, opts, filters) end)
  end

  defp show?(_result, _opts, filters) when filters != [], do: true
  defp show?(%{verdict: :pure}, opts, _filters), do: opts[:all] == true
  defp show?(%{verdict: {:unknown, _}}, opts, _), do: opts[:all] == true or opts[:unknown] == true
  defp show?(_result, _opts, _filters), do: true

  defp matches?(_mfa, []), do: true

  defp matches?({module, function, arity}, filters) do
    Enum.any?(filters, fn {want_module, want_function, want_arity} ->
      part_matches?(module, want_module) and part_matches?(function, want_function) and
        part_matches?(arity, want_arity)
    end)
  end

  defp part_matches?(_actual, nil), do: true
  defp part_matches?(same, same), do: true
  defp part_matches?(_actual, _wanted), do: false

  # "MyApp.Core", "MyApp.Core.total", "MyApp.Core.total/1" or "total/1"
  defp parse_filter(spec) do
    {spec, arity} =
      case String.split(spec, "/") do
        [spec, arity] -> {spec, String.to_integer(arity)}
        [spec] -> {spec, nil}
      end

    parts = String.split(spec, ".")

    case List.last(parts) do
      <<first, _::binary>> when first in ?a..?z ->
        {module_or_nil(Enum.drop(parts, -1)), String.to_atom(List.last(parts)), arity}

      _ ->
        {module_or_nil(parts), nil, nil}
    end
  end

  defp module_or_nil([]), do: nil
  defp module_or_nil(parts), do: Module.concat(parts)

  ## Presentation -----------------------------------------------------------

  defp verdict_tag(:pure), do: :pure
  defp verdict_tag({tag, _}), do: tag

  defp colorize(verdict, text) do
    color =
      case verdict_tag(verdict) do
        :pure -> IO.ANSI.green()
        :conditional -> IO.ANSI.cyan()
        :impure -> IO.ANSI.yellow()
        :unknown -> IO.ANSI.faint()
      end

    paint(text, color)
  end

  # Piping the report into a file or a test should not litter it with
  # escape sequences.
  defp paint(text, color) do
    if IO.ANSI.enabled?(), do: color <> text <> IO.ANSI.reset(), else: text
  end

  defp format({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"

  defp warn_skipped([]), do: :ok

  defp warn_skipped(skipped) do
    {no_debug_info, other} = Enum.split_with(skipped, &match?({_, :no_debug_info}, &1))

    if no_debug_info != [] do
      Mix.shell().error(
        "#{length(no_debug_info)} module(s) were compiled without debug_info and " <>
          "could not be analysed; their callers will report :unknown."
      )
    end

    Enum.each(other, fn {target, reason} ->
      Mix.shell().error("could not read #{inspect(target)}: #{inspect(reason)}")
    end)
  end
end
