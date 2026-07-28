defmodule Pure.DispatchTest do
  @moduledoc """
  A call that picks its target at runtime is only as pure as the
  implementations it can reach. A protocol is just a behaviour whose
  implementations live in their own modules, so both go through the same
  rule here.
  """

  use ExUnit.Case, async: true

  alias Pure.Sample.{BehaviourDispatch, Dispatch, Doubler, Formatter}
  alias Pure.Sample.{LoggingFormatter, PlainFormatter, TwiceDoubler}

  defp verdict(analysis, module, function, arity) do
    Pure.verdict(analysis, {module, function, arity})
  end

  defp tag(analysis, module, function, arity) do
    case verdict(analysis, module, function, arity) do
      :pure -> :pure
      {tag, _reasons} -> tag
    end
  end

  defp causes(analysis, module, function, arity) do
    case verdict(analysis, module, function, arity) do
      :pure -> []
      {_tag, reasons} -> for {category, mfa, _via} <- reasons, do: {category, mfa}
    end
  end

  describe "protocols" do
    setup do
      # Only the fixture is asked for; the protocols it dispatches to and
      # their implementations are pulled in by the analysis itself.
      %{analysis: Pure.analyze(modules: [Dispatch])}
    end

    test "the implementations are found without being asked for", %{analysis: analysis} do
      assert analysis.skipped == []

      assert Map.has_key?(
               analysis.results,
               {String.Chars.Pure.Sample.Quiet, :to_string, 1}
             )
    end

    test "a dispatch on a struct literal reaches only that implementation", %{analysis: analysis} do
      assert verdict(analysis, Dispatch, :quiet, 1) == :pure
    end

    test "an impure implementation makes the dispatch impure", %{analysis: analysis} do
      assert {:io, {IO, :puts, 1}} in causes(analysis, Dispatch, :loud, 1)
    end

    test "the impure implementation is named as the way in", %{analysis: analysis} do
      {:impure, reasons} = verdict(analysis, Dispatch, :loud, 1)

      assert Enum.any?(reasons, fn {_category, _mfa, via} ->
               via == {String.Chars.Pure.Sample.Loud, :to_string, 1}
             end)
    end

    test "a dispatch on an unknown term joins over every implementation", %{analysis: analysis} do
      assert {:io, {IO, :puts, 1}} in causes(analysis, Dispatch, :unknown_term, 1)
    end

    test "for/into with a map literal reaches only Collectable.Map", %{analysis: analysis} do
      assert verdict(analysis, Dispatch, :into_map, 1) == :pure
    end

    test "the protocol's own dispatching body is replaced, not followed", %{analysis: analysis} do
      # `String.Chars.to_string/1` loads the implementation before calling
      # it. Following that body would make every dispatch :code_loading.
      refute Enum.any?(causes(analysis, Dispatch, :quiet, 1), fn {category, _} ->
               category == :code_loading
             end)
    end
  end

  describe "behaviours" do
    setup do
      %{
        analysis:
          Pure.analyze(
            modules: [
              BehaviourDispatch,
              Formatter,
              PlainFormatter,
              LoggingFormatter,
              Doubler,
              TwiceDoubler
            ]
          )
      }
    end

    test "a call on a variable module resolves through the callback name", %{analysis: analysis} do
      assert {:io, {IO, :puts, 1}} in causes(analysis, BehaviourDispatch, :through_variable, 2)
    end

    test "every implementation pure means the dispatch is pure", %{analysis: analysis} do
      assert verdict(analysis, BehaviourDispatch, :double_through_variable, 2) == :pure
    end

    test "naming the behaviour module dispatches to its implementations", %{analysis: analysis} do
      assert {:io, {IO, :puts, 1}} in causes(analysis, BehaviourDispatch, :through_behaviour, 1)
    end
  end

  describe "when no implementation is known" do
    setup do
      # The implementations are deliberately left out of the analysis.
      %{analysis: Pure.analyze(modules: [BehaviourDispatch])}
    end

    test "a dispatch with nothing to join over is unknown, not pure", %{analysis: analysis} do
      assert tag(analysis, BehaviourDispatch, :through_variable, 2) == :unknown
    end

    test "the unresolved callback is reported as a runtime decision", %{analysis: analysis} do
      assert causes(analysis, BehaviourDispatch, :double_through_variable, 2) ==
               [{:dynamic_call, nil}]
    end
  end
end
