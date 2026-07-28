defmodule Pure.ErlangTest do
  use ExUnit.Case, async: true

  @module :pure_sample_erl

  setup_all do
    %{analysis: Pure.analyze(modules: [@module])}
  end

  defp verdict(%{analysis: analysis}, function, arity) do
    Pure.verdict(analysis, {@module, function, arity})
  end

  defp reasons(context, function, arity) do
    {_tag, reasons} = verdict(context, function, arity)
    for {category, mfa, _via} <- reasons, do: {category, mfa}
  end

  test "the module was readable", %{analysis: analysis} do
    assert analysis.skipped == []
  end

  test "arithmetic", context do
    assert verdict(context, :add, 2) == :pure
  end

  test "lists:foldl with an inline fun", context do
    assert verdict(context, :sum, 1) == :pure
  end

  test "a fun bound to a variable and applied", context do
    assert verdict(context, :bound_fun, 1) == :pure
  end

  test "a captured pure function", context do
    assert verdict(context, :capture_pure, 1) == :pure
  end

  test "lists:map over an argument is conditional", context do
    assert verdict(context, :hof, 2) == {:conditional, [2]}
  end

  test "applying an argument is conditional", context do
    assert verdict(context, :applies, 1) == {:conditional, [1]}
  end

  test "the ! operator", context do
    assert reasons(context, :sends, 1) == [{:message, nil}]
  end

  test "receive", context do
    assert reasons(context, :receives, 0) == [{:message_receive, nil}]
  end

  test "auto-imported put/2 resolves to the erlang BIF", context do
    assert reasons(context, :dict, 1) == [{:process_dictionary, {:erlang, :put, 2}}]
  end

  test "auto-imported self/0 resolves to the erlang BIF", context do
    assert reasons(context, :local_bif, 0) == [{:process, {:erlang, :self, 0}}]
  end

  test "auto-imported spawn/1 resolves to the erlang BIF", context do
    assert reasons(context, :spawns, 1) == [{:process, {:erlang, :spawn, 1}}]
  end

  test "ets", context do
    assert reasons(context, :table, 1) == [{:ets, {:ets, :lookup, 2}}]
  end

  test "a captured impure function passed to lists:foreach", context do
    assert reasons(context, :capture_impure, 1) == [{:io, {:erlang, :display, 1}}]
  end

  test "apply/3 is unknown, not impure", context do
    assert {:unknown, [{:dynamic_call, {:erlang, :apply, 3}, nil}]} =
             verdict(context, :dynamic, 2)
  end

  test "an -import turns into a call to the imported module" do
    analysis = Pure.analyze(modules: [:pure_sample_erl])
    assert Pure.verdict(analysis, {:pure_sample_erl, :imported, 1}) == :pure
  end

  test "the -pure_annotated attribute is read", %{analysis: analysis} do
    assert %{annotated: true} = analysis.results[{@module, :add, 2}]
    assert %{annotated: false} = analysis.results[{@module, :hof, 2}]
  end

  test "an annotated Erlang function that is not pure is a violation", %{analysis: analysis} do
    assert [{{@module, :annotated_impure, 1}, {:impure, _}}] = Pure.violations(analysis)
  end
end
