defmodule PureFunTest do
  use ExUnit.Case, async: true

  doctest PureFun

  test "verdict/2 tells apart a function that was not analysed" do
    analysis = PureFun.analyze(modules: [PureFun.Sample])
    assert PureFun.verdict(analysis, {PureFun.Sample, :add, 2}) == :pure
    assert PureFun.verdict(analysis, {Nope, :nope, 0}) == :not_analyzed
  end

  test "pure? is false for anything that is not a promise" do
    analysis = PureFun.analyze(modules: [PureFun.Sample])
    assert PureFun.pure?(analysis, {PureFun.Sample, :add, 2})
    refute PureFun.pure?(analysis, {PureFun.Sample, :writes, 1})
    refute PureFun.pure?(analysis, {PureFun.Sample, :hof, 2})
    refute PureFun.pure?(analysis, {PureFun.Sample, :dynamic, 2})
  end

  test "a module whose code cannot be read is skipped rather than assumed pure" do
    # Preloaded modules are in the runtime before any code path exists,
    # so there is no beam file to read abstract code from.
    %{results: results, skipped: skipped} = PureFun.analyze(modules: [:erlang])
    assert results == %{}
    assert [{:erlang, :no_debug_info}] = skipped
  end

  test "the @pure_fun annotation is recorded as a persisted attribute" do
    defmodule Annotated do
      use PureFun

      @pure_fun true
      def kept(x), do: x

      def plain(x), do: x

      @pure_fun true
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
      use PureFun

      @pure_fun true
      def first(x), do: x
      def second(x), do: x
    end

    assert annotations(OnlyFirst) == [first: 1]
  end

  test "an annotation on a multi-clause function is recorded once" do
    defmodule MultiClause do
      use PureFun

      @pure_fun true
      def run(0), do: :zero
      def run(n), do: n
    end

    assert annotations(MultiClause) == [run: 1]
  end

  test "a waiver is recorded next to the function it belongs to" do
    defmodule Waived do
      use PureFun

      @pure_fun except: [:time, :io]
      def stamped(x), do: x

      @pure_fun true
      def plain(x), do: x
    end

    assert Enum.sort(annotations(Waived)) == [{:plain, 1}, {:stamped, 1, [:io, :time]}]
  end

  test "a default argument is annotated at every arity it produces" do
    defmodule Defaults do
      use PureFun

      @pure_fun true
      def fee(amount, rate \\ 0.03), do: amount * rate
    end

    assert Enum.sort(annotations(Defaults)) == [fee: 1, fee: 2]
  end

  test "a module-wide annotation is recorded once, for the module" do
    defmodule WholeModule do
      use PureFun

      @pure_fun_module except: [:time]

      def stamped(x), do: x
    end

    assert WholeModule.__info__(:attributes) |> Keyword.get_values(:pure_fun_module) ==
             [[except: [:time]]]
  end

  test "a misspelt effect class fails the compile rather than waiving nothing" do
    assert_raise ArgumentError, ~r/@pure_fun on .*\.stamped\/1 waives :tyme/, fn ->
      defmodule Misspelt do
        use PureFun

        @pure_fun except: [:tyme]
        def stamped(x), do: x
      end
    end
  end

  test "@pure_fun false says what to do instead" do
    assert_raise ArgumentError, ~r/is set to `false`.*credo:disable-for-next-line/s, fn ->
      defmodule OptedOut do
        use PureFun

        @pure_fun false
        def plain(x), do: x
      end
    end
  end

  test "a module-wide annotation is checked too" do
    assert_raise ArgumentError, ~r/@pure_fun_module on .* waives :tyme/, fn ->
      defmodule MisspeltModule do
        use PureFun

        @pure_fun_module except: [:tyme]

        def plain(x), do: x
      end
    end
  end

  defp annotations(module) do
    module.__info__(:attributes)
    |> Keyword.get_values(:pure_fun_annotated)
    |> List.flatten()
  end

  describe "checking a project's annotations" do
    setup do
      %{
        analysis:
          PureFun.analyze(
            modules: [
              PureFun.Sample.Waivers,
              PureFun.Sample.PureModule,
              PureFun.Sample.PureModule.Strict
            ]
          )
      }
    end

    test "an effect the annotation owns up to is not a violation", %{analysis: analysis} do
      assert PureFun.verdict(analysis, {PureFun.Sample.Waivers, :stamped, 1}) ==
               {:impure, [{:time, {DateTime, :utc_now, 0}, nil}]}

      refute List.keymember?(
               PureFun.violations(analysis),
               {PureFun.Sample.Waivers, :stamped, 1},
               0
             )
    end

    test "only the effects that were not waived are reported", %{analysis: analysis} do
      assert PureFun.violations(analysis) == [
               {{PureFun.Sample.PureModule, :writes, 1},
                {:impure, [{:io, {IO, :puts, 1}, {PureFun.Sample.PureModule, :shout, 1}}]}},
               {{PureFun.Sample.PureModule.Strict, :now_and_then, 1},
                {:impure, [{:time, {DateTime, :utc_now, 0}, nil}]}},
               {{PureFun.Sample.Waivers, :calls_a_waived_function, 1},
                {:impure,
                 [{:time, {DateTime, :utc_now, 0}, {PureFun.Sample.Waivers, :stamped, 1}}]}},
               {{PureFun.Sample.Waivers, :still_writes, 1},
                {:impure, [{:io, {IO, :puts, 1}, nil}]}}
             ]
    end

    test "a waiver that has outlived its effect is reported apart", %{analysis: analysis} do
      assert PureFun.stale_waivers(analysis) == [
               {{PureFun.Sample.Waivers, :outgrew_its_waiver, 1}, [:time]},
               {{PureFun.Sample.Waivers, :still_writes, 1}, [:time]}
             ]
    end

    test "a module-wide waiver one function needs is not stale for the rest", %{
      analysis: analysis
    } do
      refute List.keymember?(PureFun.stale_waivers(analysis), PureFun.Sample.PureModule, 0)
    end

    test "a function may not widen what its module waives", %{analysis: analysis} do
      assert PureFun.annotation_problems(analysis) == [
               {{PureFun.Sample.PureModule, :widened, 1}, {:widens, [:io]}}
             ]
    end

    test "a module-wide claim covers public functions only", %{analysis: analysis} do
      assert %{annotation: %{scope: :module}} =
               analysis.results[{PureFun.Sample.PureModule, :plain, 2}]

      assert %{annotation: nil} = analysis.results[{PureFun.Sample.PureModule, :shout, 1}]
    end

    test "a nested module answers for itself", %{analysis: analysis} do
      assert %{annotation: %{scope: :module, except: []}} =
               analysis.results[{PureFun.Sample.PureModule.Strict, :double, 1}]

      # The same body passes in the module that encloses it.
      assert PureFun.verdict(analysis, {PureFun.Sample.PureModule, :stamped, 1}) ==
               PureFun.verdict(analysis, {PureFun.Sample.PureModule.Strict, :now_and_then, 1})
    end

    test "the functions the compiler writes are nobody's promise", %{analysis: analysis} do
      assert %{annotation: nil} = analysis.results[{PureFun.Sample.PureModule, :__info__, 1}]
    end
  end

  test "a module that does not exist is reported" do
    %{results: results, skipped: skipped} = PureFun.analyze(modules: [NoSuchModuleAtAll])
    assert results == %{}
    assert [{NoSuchModuleAtAll, :not_found}] = skipped
  end
end
