# Only compiled when the project using this library has Credo of its own.
if Code.ensure_loaded?(Credo.Check) do
  defmodule Pure.Check.Purity do
    use Credo.Check,
      id: "PUR0001",
      run_on_all: true,
      category: :warning,
      base_priority: :high,
      param_defaults: [known: %{}, follow_deps: true],
      explanations: [
        check: """
        Functions annotated `@pure` are supposed to compute a return value and
        nothing else. This check reads the compiled code of the whole project,
        follows every call the annotated function can make, and reports the
        ones that reach an effect after all.

            defmodule Payments.Core do
              use Pure

              @pure true
              def fee(amount, rate), do: round(amount * rate)

              @pure except: [:time]
              def quote(amount), do: {DateTime.utc_now(), fee(amount, 0.03)}
            end

        `except:` waives whole classes of effect for one function, and waives
        them for that function alone: a caller annotated plain `@pure` still
        fails on the clock its callee reads. That is what stops a waiver from
        laundering effects through the rest of the call graph.

        A whole module can make the claim at once, which is the useful form
        for a functional core, because a function added to it tomorrow is
        covered the day it lands:

            @pure_module except: [:time]

        A function inside such a module may narrow what its module waives,
        never widen it. To exempt one function entirely, use Credo's own
        `# credo:disable-for-next-line Pure.Check.Purity`.

        The effect classes an annotation may name are the ones the analyser
        reports: `:io`, `:file`, `:network`, `:system`, `:time`, `:random`,
        `:process`, `:process_dictionary`, `:message`, `:message_receive`,
        `:ets`, `:persistent_term`, `:mutable_state`, `:code_loading`,
        `:port`, `:tracing`, and the three that mean the analyser lost the
        trail rather than found an effect: `:dynamic_call`, `:higher_order`
        and `:unknown`.

        Two verdicts are not violations. A higher-order function is pure in
        itself — whoever hands it `&IO.puts/1` fails on their own annotation
        — so `pure if the fun given as argument 2 is pure` keeps the claim.
        A function whose purity could not be determined does not: an
        annotation nobody can check is the case this tool exists to report,
        and waiving it takes saying `except: [:unknown]`.

        This check reads compiled beam files and never compiles anything
        itself, so annotations in a module that is missing from the build, or
        older than its source, are reported as unchecked rather than passed.
        Run `mix compile` before `mix credo` in CI.
        """,
        params: [
          known: """
          Purity of functions the analyser cannot work out for itself, as a
          `%{{module, function, arity} => answer}` map, where an answer is
          `:pure`, `{:impure, class}` or `{:hof, positions}`. Merged over the
          `pure: [known: %{...}]` entry in `mix.exs`, which both this check
          and `mix pure` read.
          """,
          follow_deps: """
          Follow calls into dependencies. On by default: without it every
          call into a library is `:unknown`, and an annotation that reaches
          one cannot be kept.
          """
        ]
      ]

    alias Credo.Check.Params
    alias Credo.IssueMeta
    alias Credo.SourceFile
    alias Pure.{Analyzer, Annotation, Beam, Source}

    @doc false
    @impl true
    def run_on_all_source_files(exec, source_files, params) do
      annotated =
        for source_file <- source_files,
            modules = Source.annotations(SourceFile.ast(source_file)),
            modules != [],
            do: {source_file, modules}

      # The analysis is worth nothing to a project that makes no claims,
      # and it reads every beam file in the build to produce it.
      issues = if annotated == [], do: [], else: report(annotated, analyze(params), params)

      append_issues_and_timings(issues, exec)

      :ok
    end

    # One analysis for the whole run. Purity is a property of the call
    # graph rather than of a file, so a module reached from forty
    # annotated functions is still read, scanned and settled exactly once.
    defp analyze(params) do
      Pure.analyze(
        paths: Beam.build_dirs(deps: Params.get(params, :follow_deps, __MODULE__)),
        known: known(params)
      )
    end

    defp known(params) do
      Mix.Project.config()
      |> Keyword.get(:pure, [])
      |> Keyword.get(:known, %{})
      |> Map.merge(Params.get(params, :known, __MODULE__))
    end

    defp report(annotated, analysis, params) do
      analyzed = MapSet.new(analysis.results, fn {{module, _f, _a}, _result} -> module end)

      Enum.flat_map(annotated, fn {source_file, modules} ->
        issue_meta = IssueMeta.for(source_file, params)

        Enum.flat_map(
          modules,
          &module_issues(&1, issue_meta, source_file, analysis, analyzed)
        )
      end)
    end

    ## Is there anything to check against? --------------------------------

    defp module_issues(entry, issue_meta, source_file, analysis, analyzed) do
      case unchecked(entry.module, source_file, analyzed) do
        # Nothing to check the claims against, but an annotation that is
        # wrong in itself is wrong in the source and worth saying anyway.
        {:unchecked, message} ->
          [issue(issue_meta, message, entry.line, "defmodule")] ++
            annotation_issues(entry, issue_meta, nil)

        :ok ->
          annotation_issues(entry, issue_meta, analysis)
      end
    end

    # An annotation that cannot be checked is not an annotation that
    # passes. Both of these mean the build is out of date, and both fail.
    defp unchecked(module, source_file, analyzed) do
      cond do
        not MapSet.member?(analyzed, module) ->
          {:unchecked,
           "#{inspect(module)} claims purity, but there is no compiled module to check " <>
             "it against; run mix compile"}

        stale?(module, source_file.filename) ->
          {:unchecked,
           "#{inspect(module)} has changed since it was last compiled, so its purity " <>
             "claims are being checked against old code; run mix compile"}

        true ->
          :ok
      end
    end

    defp stale?(module, filename) do
      with path when is_list(path) <- :code.which(module),
           {:ok, %{mtime: compiled_at}} <- File.stat(List.to_string(path), time: :posix),
           {:ok, %{mtime: written_at}} <- File.stat(filename, time: :posix) do
        written_at > compiled_at
      else
        _unknown -> false
      end
    end

    ## What the annotations claim -----------------------------------------

    defp annotation_issues(entry, issue_meta, analysis) do
      {module_except, module_problems} = module_annotation(entry, issue_meta)

      functions =
        Enum.flat_map(
          entry.functions,
          &function_issues(&1, entry, module_except, issue_meta, analysis)
        )

      module_problems ++ functions ++ module_waiver(entry, module_except, issue_meta, analysis)
    end

    defp module_annotation(%{annotation: nil}, _issue_meta), do: {nil, []}

    defp module_annotation(%{annotation: written, module: module}, issue_meta) do
      case Annotation.parse(written.value) do
        {:ok, except} ->
          {except, []}

        # A module waiver nobody can read constrains nothing: reporting it
        # once beats calling every waiver below it a widening.
        {:error, problem} ->
          message =
            "@pure_module on #{inspect(module)} #{Annotation.describe_problem(problem)}"

          {nil, [issue(issue_meta, message, written.line, "@pure_module")]}
      end
    end

    defp function_issues(function, entry, module_except, issue_meta, analysis) do
      case effective(function, module_except) do
        nil ->
          []

        {:module, except} ->
          annotation = %{except: except, scope: :module, problems: []}
          verify(function, entry.module, annotation, issue_meta, analysis)

        {:function, written} ->
          case Annotation.parse(written.value) do
            {:error, problem} ->
              [problem_issue(function, problem, issue_meta, written.line)]

            parsed ->
              annotation = Annotation.build(parsed, :function, module_except)

              Enum.map(
                annotation.problems,
                &problem_issue(function, &1, issue_meta, written.line)
              ) ++ verify(function, entry.module, annotation, issue_meta, analysis)
          end
      end
    end

    # A module-wide claim is a claim about the module's public interface.
    # A private function is nobody's promise, so it is only checked when
    # it says so itself.
    defp effective(%{annotation: nil}, nil), do: nil
    defp effective(%{annotation: nil, public?: false}, _module_except), do: nil
    defp effective(%{annotation: nil}, module_except), do: {:module, module_except}
    defp effective(%{annotation: written}, _module_except), do: {:function, written}

    defp verify(_function, _module, _annotation, _issue_meta, nil), do: []

    defp verify(function, module, annotation, issue_meta, analysis) do
      case Map.fetch(analysis.results, {module, function.name, function.arity}) do
        :error ->
          message =
            "#{name(function)} is #{claim(annotation)} but is not in the compiled " <>
              "module; run mix compile"

          [issue(issue_meta, message, function.line, function.name)]

        {:ok, result} ->
          violation(function, annotation, result, issue_meta) ++
            waiver(function, annotation, result, issue_meta)
      end
    end

    defp violation(function, annotation, result, issue_meta) do
      case Annotation.check(result.verdict, annotation.except) do
        :ok ->
          []

        {:violation, verdict} ->
          message =
            "#{name(function)} is #{claim(annotation)} but is #{Analyzer.explain(verdict)}"

          [
            issue_meta
            |> issue(message, function.line, function.name)
            |> with_effects(result.effects)
          ]
      end
    end

    # A waiver that has outlived its effect makes the annotation say
    # something untrue, but it can only ever make the check more
    # permissive, so it is worth a word and not a failed build.
    defp waiver(function, %{scope: :function, except: except}, result, issue_meta)
         when except != [] do
      case Annotation.stale(result.effects, except) do
        [] ->
          []

        stale ->
          message = "#{name(function)} waives #{list(stale)}, which it does not do"

          [advice(issue_meta, message, function.line, function.name)]
      end
    end

    defp waiver(_function, _annotation, _result, _issue_meta), do: []

    # A module waiver is judged over the module: it exists so that some
    # function may read the clock, and the ones that do not are the point
    # of the annotation rather than a finding.
    defp module_waiver(_entry, nil, _issue_meta, _analysis), do: []
    defp module_waiver(_entry, [], _issue_meta, _analysis), do: []
    defp module_waiver(_entry, _module_except, _issue_meta, nil), do: []

    defp module_waiver(entry, module_except, issue_meta, analysis) do
      effects =
        for function <- entry.functions,
            match?({:module, _except}, effective(function, module_except)),
            {:ok, result} <-
              [Map.fetch(analysis.results, {entry.module, function.name, function.arity})],
            effect <- result.effects,
            do: effect

      case Annotation.stale(effects, module_except) do
        [] ->
          []

        stale ->
          message =
            "@pure_module on #{inspect(entry.module)} waives #{list(stale)}, " <>
              "which nothing in the module does"

          [advice(issue_meta, message, entry.annotation.line, "@pure_module")]
      end
    end

    ## Issues --------------------------------------------------------------

    defp problem_issue(function, problem, issue_meta, line) do
      message = "@pure on #{name(function)} #{Annotation.describe_problem(problem)}"

      issue(issue_meta, message, line, "@pure")
    end

    defp issue(issue_meta, message, line, trigger) do
      format_issue(issue_meta, message: message, line_no: line, trigger: to_string(trigger))
    end

    # Reported, never fatal: an issue with an exit status of its own would
    # fail a build over an annotation that is only out of date, and the
    # low priority keeps it out of the way of the findings that matter.
    defp advice(issue_meta, message, line, trigger) do
      format_issue(issue_meta,
        message: message,
        line_no: line,
        trigger: to_string(trigger),
        priority: Credo.Priority.to_integer(:low),
        exit_status: 0
      )
    end

    # `format_issue/2` has no room for it, and the reasons beyond the
    # first are what a formatter would want to show.
    defp with_effects(issue, effects), do: %{issue | meta: [effects: effects]}

    defp name(%{name: name, arity: arity}), do: "#{name}/#{arity}"

    defp claim(%{scope: :module} = annotation), do: "covered by #{Annotation.explain(annotation)}"
    defp claim(annotation), do: "annotated #{Annotation.explain(annotation)}"

    defp list(atoms), do: Enum.map_join(atoms, ", ", &inspect/1)
  end
end
