defmodule Pure.AnalyzerTest do
  use ExUnit.Case, async: true

  doctest Pure.Analyzer

  setup_all do
    %{analysis: Pure.analyze(modules: [Pure.Sample])}
  end

  defp verdict(%{analysis: analysis}, function, arity) do
    Pure.verdict(analysis, {Pure.Sample, function, arity})
  end

  defp tag(context, function, arity) do
    case verdict(context, function, arity) do
      :pure -> :pure
      {tag, _} -> tag
    end
  end

  defp reasons(context, function, arity) do
    {_tag, reasons} = verdict(context, function, arity)
    for {category, mfa, _via} <- reasons, do: {category, mfa}
  end

  describe "pure functions" do
    test "arithmetic", context do
      assert verdict(context, :add, 2) == :pure
    end

    test "an inline fun that is itself pure", context do
      assert verdict(context, :double_all, 1) == :pure
    end

    test "a captured pure function", context do
      assert verdict(context, :capture_pure, 1) == :pure
    end

    test "a call to a pure function in the same module", context do
      assert verdict(context, :via_pure_local, 1) == :pure
    end

    test "guards and multiple clauses", context do
      assert verdict(context, :guarded, 1) == :pure
    end

    test "comprehensions", context do
      assert verdict(context, :comprehension, 1) == :pure
    end

    test "raising is a result, not an effect", context do
      assert verdict(context, :raises, 1) == :pure
    end

    test "self-recursion terminates at the least fixpoint", context do
      assert verdict(context, :recursive, 1) == :pure
    end

    test "mutual recursion terminates at the least fixpoint", context do
      assert verdict(context, :mutually_recursive_a, 1) == :pure
      assert verdict(context, :mutually_recursive_b, 1) == :pure
    end
  end

  describe "impure functions" do
    test "io", context do
      assert reasons(context, :writes, 1) == [{:io, {IO, :puts, 1}}]
    end

    test "sending", context do
      assert reasons(context, :sends, 1) == [{:message, {:erlang, :send, 2}}]
    end

    test "receiving", context do
      assert reasons(context, :receives, 0) == [{:message_receive, nil}]
    end

    test "the process dictionary", context do
      assert reasons(context, :process_dictionary, 1) ==
               [{:process_dictionary, {Process, :put, 2}}]
    end

    test "the clock", context do
      assert reasons(context, :reads_clock, 0) == [{:time, {DateTime, :utc_now, 0}}]
    end

    test "spawning", context do
      assert reasons(context, :spawns, 1) == [{:process, {:erlang, :spawn, 1}}]
    end

    test "shared tables", context do
      assert reasons(context, :table, 1) == [{:ets, {:ets, :lookup, 2}}]
    end
  end

  describe "effects travel along the call graph" do
    test "one hop, keeping the original cause", context do
      assert reasons(context, :one_hop, 1) == [{:io, {IO, :puts, 1}}]
    end

    test "two hops", context do
      assert reasons(context, :two_hops, 1) == [{:io, {IO, :puts, 1}}]
    end

    test "the direct callee is reported as the way in", context do
      {:impure, [{_, _, via}]} = verdict(context, :two_hops, 1)
      assert via == {Pure.Sample, :one_hop, 1}
    end

    test "an impure function captured into a pure higher-order function", context do
      assert reasons(context, :impure_capture, 1) == [{:io, {IO, :puts, 1}}]
    end

    test "an impure inline fun", context do
      assert reasons(context, :impure_inline_fun, 1) == [{:io, {IO, :inspect, 1}}]
    end
  end

  describe "higher-order functions" do
    test "passing an argument straight to a known higher-order function", context do
      assert verdict(context, :hof, 2) == {:conditional, [2]}
    end

    test "applying an argument", context do
      assert verdict(context, :applies, 1) == {:conditional, [1]}
    end

    test "passing an argument to a higher-order function in the project", context do
      assert verdict(context, :passes_through, 2) == {:conditional, [2]}
    end

    test "a conditional function called with a pure fun is pure", context do
      assert verdict(context, :hof_with_pure_fun, 1) == :pure
    end

    test "a conditional function called with an impure fun is impure", context do
      assert reasons(context, :hof_with_impure_fun, 1) == [{:io, {IO, :puts, 1}}]
    end
  end

  describe "resolving funs" do
    test "a fun bound to a variable and passed on", context do
      assert verdict(context, :bound_fun, 1) == :pure
    end

    test "an impure fun bound to a variable", context do
      assert reasons(context, :bound_impure_fun, 1) == [{:io, {IO, :puts, 1}}]
    end

    test "two higher-order positions at once", context do
      assert verdict(context, :two_position_hof, 3) == {:conditional, [2, 3]}
    end

    test "a non-fun in a higher-order position is not an unresolved fun", context do
      assert verdict(context, :literal_at_hof_position, 1) == :pure
    end
  end

  describe "when the trail is lost" do
    test "a dynamic apply is unknown, not impure", context do
      assert tag(context, :dynamic, 2) == :unknown
      assert reasons(context, :dynamic, 2) == [{:dynamic_call, {:erlang, :apply, 3}}]
    end

    test "an unresolvable fun is unknown", context do
      assert tag(context, :unresolvable_fun, 1) == :unknown
    end

    test "a call on a module held in a variable is unknown", context do
      assert reasons(context, :dynamic_module, 1) == [{:dynamic_call, nil}]
    end
  end

  describe "receive" do
    test "with an after clause", context do
      assert reasons(context, :receive_after, 0) == [{:message_receive, nil}]
    end
  end

  describe "explain/1" do
    test "several higher-order positions read as a list" do
      assert Pure.Analyzer.explain({:conditional, [2, 3]}) ==
               "pure if the funs given as argument 2 and 3 are pure"
    end

    test "a long list of reasons is cut short" do
      reasons = for n <- 1..6, do: {:io, {IO, :puts, n}, nil}

      explanation = Pure.Analyzer.explain({:impure, reasons})

      assert explanation =~ "(and 3 more)"
      refute explanation =~ "IO.puts/4"
    end

    test "an effect reached through a callee names both" do
      reason = {:io, {IO, :puts, 1}, {App, :log, 1}}

      assert Pure.Analyzer.explain({:impure, [reason]}) ==
               "impure: performs I/O (IO.puts/1) via App.log/1"
    end
  end

  describe "annotations" do
    test "@pure true is carried through to the result", context do
      assert %{annotated: true} = context.analysis.results[{Pure.Sample, :add, 2}]
      assert %{annotated: false} = context.analysis.results[{Pure.Sample, :writes, 1}]
    end

    test "an annotated function that is not pure is a violation", context do
      assert Pure.violations(context.analysis) ==
               [
                 {{Pure.Sample, :annotated_but_impure, 1},
                  {:impure, [{:io, {IO, :puts, 1}, nil}]}}
               ]
    end
  end

  describe "exports" do
    test "public functions are marked exported", context do
      assert %{exported: true} = context.analysis.results[{Pure.Sample, :add, 2}]
    end
  end

  test "an unknown module is reported rather than guessed" do
    forms = %{
      Fake => [
        {:attribute, 1, :export, [{:run, 0}]},
        {:function, 1, :run, 0,
         [
           {:clause, 1, [], [],
            [{:call, 1, {:remote, 1, {:atom, 1, NoSuchLib}, {:atom, 1, :go}}, []}]}
         ]}
      ]
    }

    assert %{verdict: {:unknown, [{:unknown, {NoSuchLib, :go, 0}, nil}]}} =
             Pure.Analyzer.analyze(forms)[{Fake, :run, 0}]
  end

  test "the knowledge base can be extended per project" do
    forms = %{
      Fake => [
        {:function, 1, :run, 0,
         [
           {:clause, 1, [], [],
            [{:call, 1, {:remote, 1, {:atom, 1, NoSuchLib}, {:atom, 1, :go}}, []}]}
         ]}
      ]
    }

    known = %{{NoSuchLib, :go, 0} => {:impure, :network}}

    assert %{verdict: {:impure, [{:network, {NoSuchLib, :go, 0}, nil}]}} =
             Pure.Analyzer.analyze(forms, known: known)[{Fake, :run, 0}]
  end
end
