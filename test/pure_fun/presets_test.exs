defmodule PureFun.PresetsTest do
  use ExUnit.Case, async: true

  alias PureFun.{Analyzer, Knowledge, Presets}

  doctest PureFun.Presets

  describe "the tables" do
    for name <- Presets.names() do
      test "#{name} only gives answers the analyser understands" do
        for {{_m, _f, arity} = mfa, answer} <- apply(Presets, unquote(name), []) do
          assert valid?(answer, arity), "#{inspect(mfa)} => #{inspect(answer)}"
        end
      end
    end

    test "no two presets answer for the same function, so their order does not matter" do
      tables = Enum.map(Presets.names(), &apply(Presets, &1, []))

      for a <- tables, b <- tables, a != b do
        assert MapSet.disjoint?(MapSet.new(Map.keys(a)), MapSet.new(Map.keys(b)))
      end
    end
  end

  defp valid?(:pure, _arity), do: true
  defp valid?({:impure, category}, _arity), do: category in Knowledge.categories()

  defp valid?({:hof, positions}, arity),
    do: positions != [] and Enum.all?(positions, &(&1 in 1..arity))

  defp valid?(_answer, _arity), do: false

  describe "known/1" do
    test "merges the named presets" do
      known = Presets.known(presets: [:ecto, :gettext])

      assert known[{Ecto.Changeset, :cast, 3}] == :pure
      assert known[{Gettext, :dpgettext, 5}] == {:impure, :process_dictionary}
    end

    test "leaves out the presets that are not named" do
      refute Map.has_key?(Presets.known(presets: [:ecto]), {Gettext, :dpgettext, 5})
    end

    test "an unknown preset is an error rather than nothing" do
      assert_raise ArgumentError, ~r/unknown pure_fun preset :ectoo.*:ecto, :gettext/, fn ->
        Presets.known(presets: [:ectoo])
      end
    end
  end

  # What a schema module compiles to, reduced to the calls that matter.
  describe "a changeset analysed with the Ecto preset" do
    setup do
      %{analysis: Analyzer.analyze(%{Schema => forms()}, known: Presets.ecto())}
    end

    test "casting and validating is pure", %{analysis: analysis} do
      assert analysis[{Schema, :changeset, 2}].verdict == :pure
    end

    test "a query is still an effect", %{analysis: analysis} do
      assert {:impure, [{:network, {Ecto.Changeset, :unsafe_validate_unique, 3}, nil}]} =
               analysis[{Schema, :unique, 2}].verdict
    end

    test "a validator is only as pure as the fun it is given", %{analysis: analysis} do
      assert analysis[{Schema, :validate, 2}].verdict == {:conditional, [2]}
    end
  end

  defp forms do
    [
      function(:changeset, [var(:Cs), var(:Attrs)], [
        call(Ecto.Changeset, :validate_required, [
          call(Ecto.Changeset, :cast, [var(:Cs), var(:Attrs), {nil, 1}]),
          {nil, 1}
        ])
      ]),
      function(:unique, [var(:Cs), var(:Repo)], [
        call(Ecto.Changeset, :unsafe_validate_unique, [var(:Cs), {:atom, 1, :email}, var(:Repo)])
      ]),
      function(:validate, [var(:Cs), var(:Fun)], [
        call(Ecto.Changeset, :validate_change, [var(:Cs), {:atom, 1, :name}, var(:Fun)])
      ])
    ]
  end

  defp function(name, params, body),
    do: {:function, 1, name, length(params), [{:clause, 1, params, [], body}]}

  defp call(m, f, args), do: {:call, 1, {:remote, 1, {:atom, 1, m}, {:atom, 1, f}}, args}
  defp var(name), do: {:var, 1, name}
end
