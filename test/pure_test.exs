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

  test "the @pure annotation is recorded as a persisted attribute" do
    defmodule Annotated do
      use Pure

      @pure true
      def kept(x), do: x

      def plain(x), do: x

      @pure true
      defp helper(x), do: x

      def uses_helper(x), do: helper(x)
    end

    # Each accumulated value persists as its own attribute entry, which
    # is why the analyser reads every one of them rather than the first.
    annotated = annotations(Annotated)

    assert Enum.sort(annotated) == [helper: 1, kept: 1]
  end

  test "the annotation applies to the function, not to every later one" do
    defmodule OnlyFirst do
      use Pure

      @pure true
      def first(x), do: x
      def second(x), do: x
    end

    assert annotations(OnlyFirst) == [first: 1]
  end

  test "an annotation on a multi-clause function is recorded once" do
    defmodule MultiClause do
      use Pure

      @pure true
      def run(0), do: :zero
      def run(n), do: n
    end

    assert annotations(MultiClause) == [run: 1]
  end

  defp annotations(module) do
    module.__info__(:attributes)
    |> Keyword.get_values(:pure_annotated)
    |> List.flatten()
  end

  test "a module that does not exist is reported" do
    %{results: results, skipped: skipped} = Pure.analyze(modules: [NoSuchModuleAtAll])
    assert results == %{}
    assert [{NoSuchModuleAtAll, :not_found}] = skipped
  end
end
