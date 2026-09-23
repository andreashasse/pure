defmodule Mix.Tasks.PureFun do
  @shortdoc "Reports which functions are pure"

  @moduledoc """
  Reports which functions in the project have no side effects.

  Calls into dependencies are followed by default, so a function that
  reaches an effect through a library is reported as impure rather than
  unknown.

      mix pure_fun                     # summary for every module in the project
      mix pure_fun MyApp.Core          # every function in one module
      mix pure_fun MyApp.Core.total/1  # one function, with the reasons
      mix pure_fun --check             # fail if an annotation is not kept

  ## Options

    * `--check` - exit non-zero if an annotation is not kept: a `@pure_fun`
      function that reaches an effect it did not waive, or an annotation
      that is wrong in itself. Waivers nothing needs any more are
      reported without failing anything. This is the CI mode, and
      `PureFun.Check.Purity` is the same thing as a Credo check.
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
          pure_fun: [
            known: %{
              {MyLib.Cache, :get, 1} => {:impure, :ets},
              {MyLib.Fold, :run, 2} => {:hof, [2]}
            }
          ]
        ]
      end
  """

  use Mix.Task

  alias PureFun.{Analyzer, Annotation}

  @switches [check: :boolean, all: :boolean, deps: :boolean, unknown: :boolean, private: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, filters} = OptionParser.parse!(argv, strict: @switches)
    Mix.Task.run("compile", [])

    config = Keyword.get(Mix.Project.config(), :pure_fun, [])
    deps? = Keyword.get(opts, :deps, true)
    filters = Enum.map(filters, &parse_filter/1)
    roots = roots(filters)

    Mix.shell().info(
      "Analysing #{count(roots, "module")}" <>
        if(deps?, do: " and the dependencies they call", else: "") <> "..."
    )

    {microseconds, analysis} =
      :timer.tc(fn ->
        PureFun.analyze(
          paths: PureFun.Beam.build_dirs(deps: deps?),
          known: Keyword.get(config, :known, %{}),
          roots: roots
        )
      end)

    Mix.shell().info(
      "Analysed #{count(analysis.results, "function")} in " <>
        "#{Float.round(microseconds / 1_000_000, 1)} s."
    )

    warn_skipped(analysis.skipped)
    in_roots = Enum.filter(analysis.results, fn {{module, _f, _a}, _} -> module in roots end)

    if opts[:check] do
      check(%{analysis | results: Map.new(in_roots)}, deps?)
    else
      in_roots
      |> interesting(opts, filters)
      |> report(deps?)
    end
  end

  # A filter that names modules only needs those modules, and they may
  # just as well be dependencies. Anything else is about the project.
  defp roots(filters) do
    if filters != [] and Enum.all?(filters, fn {module, _f, _a} -> module end) do
      filters |> Enum.map(fn {module, _f, _a} -> module end) |> Enum.uniq()
    else
      PureFun.Beam.modules(Mix.Project.compile_path())
    end
  end

  ## Reporting --------------------------------------------------------------

  defp report([], _deps?) do
    Mix.shell().info("No matching functions.")
  end

  defp report(results, deps?) do
    results
    |> Enum.group_by(fn {{module, _, _}, _} -> module end)
    |> Enum.sort_by(fn {module, _} -> inspect(module) end)
    |> Enum.each(fn {module, functions} -> report_module(module, functions) end)

    summarize(results)
    hint(Enum.map(results, fn {_mfa, result} -> result.verdict end), deps?)
  end

  defp report_module(module, functions) do
    Mix.shell().info("\n" <> paint(inspect(module), IO.ANSI.bright()))

    functions
    |> Enum.sort_by(fn {{_, f, a}, _} -> {f, a} end)
    |> Enum.each(fn {{_, f, a}, result} ->
      name = String.pad_trailing("#{f}/#{a}", 32)
      {line, details} = describe(result.verdict)

      Mix.shell().info("  " <> name <> colorize(result.verdict, line) <> annotation(result))
      Enum.each(details, &Mix.shell().info("      " <> &1))
    end)
  end

  # A verdict with one origin per effect class reads fine on one line.
  # Anything longer gets the verdict alone on that line and one line per
  # class below it, so nothing is said twice.
  defp describe({tag, reasons} = verdict) when tag in [:impure, :unknown] do
    groups = Analyzer.group(reasons)

    if length(groups) <= 3 and Enum.all?(groups, &match?({_category, [_one]}, &1)) do
      {Analyzer.explain(verdict), []}
    else
      {to_string(tag), Enum.map(groups, &detail/1)}
    end
  end

  defp describe(verdict), do: {Analyzer.explain(verdict), []}

  defp detail({category, [{origin, via}]}) when via not in [nil, origin] do
    "#{PureFun.Knowledge.describe(category)}: #{origins([origin])} via #{format(via)}"
  end

  defp detail({category, pairs}) do
    "#{PureFun.Knowledge.describe(category)}: #{pairs |> Enum.map(&elem(&1, 0)) |> origins()}"
  end

  defp origins(origins) do
    itself = if nil in origins, do: ["directly"], else: []
    listed = if origins == [nil], do: [], else: [Analyzer.list_origins(origins)]

    Enum.join(itself ++ listed, ", ")
  end

  defp annotation(%{annotation: nil}), do: ""
  defp annotation(%{annotation: annotation}), do: "  [#{Annotation.explain(annotation)}]"

  defp summarize(results) do
    counts = Enum.frequencies_by(results, fn {_, result} -> verdict_tag(result.verdict) end)

    line =
      [:pure, :conditional, :impure, :unknown]
      |> Enum.map(&"#{Map.get(counts, &1, 0)} #{&1}")
      |> Enum.join(", ")

    Mix.shell().info("\n" <> line <> " (#{count(results, "function")})")
  end

  # Said once at the end rather than on every function it applies to.
  defp hint(verdicts, deps?) do
    lost? =
      Enum.any?(verdicts, fn
        {_tag, reasons} -> Enum.any?(reasons, &match?({:unknown, _origin, _via}, &1))
        _verdict -> false
      end)

    if lost? do
      unless deps? do
        Mix.shell().info(
          "\nCalls into dependencies were not followed (--no-deps), so they are " <>
            "unknown. Run without --no-deps to follow them."
        )
      end

      Mix.shell().info(
        "\nTo tell the analyser what a function it knows nothing about does, " <>
          "add it to `pure_fun: [known: %{...}]` in mix.exs."
      )
    end
  end

  defp count(enumerable, noun) do
    n = Enum.count(enumerable)
    "#{n} #{noun}#{if n == 1, do: "", else: "s"}"
  end

  ## Check mode -------------------------------------------------------------

  defp check(analysis, deps?) do
    violations = PureFun.violations(analysis)
    problems = PureFun.annotation_problems(analysis)

    # A waiver nothing needs any more only ever makes the check more
    # permissive, so it is said out loud and then let through.
    Enum.each(PureFun.stale_waivers(analysis), fn {mfa, stale} ->
      Mix.shell().info("#{format(mfa)} waives #{inspect(stale)}, which it does not do")
    end)

    Enum.each(problems, fn {subject, problem} ->
      Mix.shell().error("#{Annotation.subject(subject)} #{Annotation.describe_problem(problem)}")
    end)

    Enum.each(violations, fn {mfa, verdict} ->
      Mix.shell().error(
        "#{format(mfa)} is annotated @pure_fun but is #{Analyzer.explain(verdict)}"
      )
    end)

    failures = length(violations) + length(problems)
    hint(Enum.map(violations, fn {_mfa, verdict} -> verdict end), deps?)

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
    |> Enum.reject(fn {mfa, _} -> PureFun.generated?(mfa) end)
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
