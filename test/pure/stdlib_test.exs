defmodule Pure.StdlibTest do
  @moduledoc """
  Runs the analyser over Elixir's own standard library and compiler.

  Not about specific verdicts — it is the check that thousands of
  functions of real code, written by other people, neither crash the
  analyser nor come back mostly unknown. Excluded by default because it
  takes a couple of seconds.
  """

  use ExUnit.Case, async: true

  @moduletag :stdlib

  setup_all do
    ebin = :elixir |> :code.lib_dir() |> Path.join("ebin")
    %{analysis: Pure.analyze(paths: [ebin])}
  end

  defp verdicts(%{analysis: analysis}) do
    analysis.results
    |> Enum.reject(fn {mfa, _result} -> Pure.generated?(mfa) end)
    |> Enum.frequencies_by(fn
      {_mfa, %{verdict: :pure}} -> :pure
      {_mfa, %{verdict: {tag, _}}} -> tag
    end)
  end

  test "every module can be read", %{analysis: analysis} do
    assert analysis.skipped == []
  end

  test "the whole standard library is analysed", context do
    assert map_size(context.analysis.results) > 5_000
  end

  test "most functions get a definite answer", context do
    verdicts = verdicts(context)
    total = verdicts |> Map.values() |> Enum.sum()

    assert Map.fetch!(verdicts, :unknown) / total < 0.10
  end

  test "both answers are well represented, so nothing collapsed", context do
    verdicts = verdicts(context)

    assert Map.fetch!(verdicts, :pure) > 1_000
    assert Map.fetch!(verdicts, :impure) > 1_000
    assert Map.fetch!(verdicts, :conditional) > 100
  end

  test "known answers are not contradicted by the code that was read", context do
    # These have entries in the knowledge base, which has to win over
    # whatever their Erlang source appears to do.
    assert Pure.verdict(context.analysis, {String, :upcase, 1}) == :pure
    assert Pure.verdict(context.analysis, {Enum, :map, 2}) == {:conditional, [2]}
    assert {:impure, _} = Pure.verdict(context.analysis, {File, :read, 1})
  end
end
