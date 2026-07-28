defmodule PureTest do
  use ExUnit.Case, async: true

  doctest Pure

  test "verdict/2 tells apart a function that was not analysed" do
    analysis = Pure.analyze(modules: [Pure.Sample])
    assert Pure.verdict(analysis, {Pure.Sample, :add, 2}) == :pure
    assert Pure.verdict(analysis, {Nope, :nope, 0}) == :not_analyzed
  end

  test "pure? is false for anything that is not a promise" do
    analysis = Pure.analyze(modules: [Pure.Sample])
    assert Pure.pure?(analysis, {Pure.Sample, :add, 2})
    refute Pure.pure?(analysis, {Pure.Sample, :writes, 1})
    refute Pure.pure?(analysis, {Pure.Sample, :hof, 2})
    refute Pure.pure?(analysis, {Pure.Sample, :dynamic, 2})
  end

  test "a module whose code cannot be read is skipped rather than assumed pure" do
    # Preloaded modules are in the runtime before any code path exists,
    # so there is no beam file to read abstract code from.
    %{results: results, skipped: skipped} = Pure.analyze(modules: [:erlang])
    assert results == %{}
    assert [{:erlang, :no_debug_info}] = skipped
  end

  test "a module that does not exist is reported" do
    %{results: results, skipped: skipped} = Pure.analyze(modules: [NoSuchModuleAtAll])
    assert results == %{}
    assert [{NoSuchModuleAtAll, :not_found}] = skipped
  end
end
