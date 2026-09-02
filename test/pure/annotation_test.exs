defmodule Pure.AnnotationTest do
  use ExUnit.Case, async: true

  alias Pure.Annotation

  doctest Pure.Annotation

  describe "parse/1" do
    test "true is a claim with no waivers" do
      assert Annotation.parse(true) == {:ok, []}
    end

    test "waived classes are sorted and deduplicated" do
      assert Annotation.parse(except: [:time, :io, :time]) == {:ok, [:io, :time]}
    end

    test "the classes the analyser gives up with can be waived like any other" do
      assert Annotation.parse(except: [:unknown, :higher_order, :dynamic_call]) ==
               {:ok, [:dynamic_call, :higher_order, :unknown]}
    end

    test "a misspelt class is an error rather than a waiver of nothing" do
      assert Annotation.parse(except: [:time, :fyle]) == {:error, {:unknown_effects, [:fyle]}}
    end

    test "false is not an opt-out" do
      assert Annotation.parse(false) == {:error, {:invalid, false}}
    end

    test "anything that is not true or except: is rejected" do
      assert Annotation.parse(:yes) == {:error, {:invalid, :yes}}
      assert Annotation.parse([:time]) == {:error, {:invalid, [:time]}}
      assert Annotation.parse(allow: [:time]) == {:error, {:invalid, [allow: [:time]]}}
      assert Annotation.parse(except: :time) == {:error, {:invalid, :time}}
    end
  end

  describe "build/3" do
    test "a function may narrow what its module waives" do
      assert Annotation.build({:ok, [:time]}, :function, [:io, :time]) ==
               %{except: [:time], scope: :function, problems: []}
    end

    test "a function may not widen it" do
      assert Annotation.build({:ok, [:io, :time]}, :function, [:time]) ==
               %{except: [:io, :time], scope: :function, problems: [{:widens, [:io]}]}
    end

    test "a module that says nothing constrains nothing" do
      assert Annotation.build({:ok, [:io]}, :function) ==
               %{except: [:io], scope: :function, problems: []}
    end

    test "an unreadable annotation waives nothing and carries the problem" do
      assert Annotation.build({:error, {:invalid, :yes}}, :function, [:time]) ==
               %{except: [], scope: :function, problems: [{:invalid, :yes}]}
    end
  end

  describe "check/2" do
    test "a waived class is not a violation" do
      verdict = {:impure, [{:time, {DateTime, :utc_now, 0}, nil}]}

      assert Annotation.check(verdict, [:time]) == :ok
    end

    test "only the classes that were not waived are reported" do
      time = {:time, {DateTime, :utc_now, 0}, nil}
      io = {:io, {IO, :puts, 1}, nil}

      assert Annotation.check({:impure, [time, io]}, [:time]) == {:violation, {:impure, [io]}}
    end

    test "waiving every effect that is left drops the verdict entirely" do
      io = {:io, {IO, :puts, 1}, nil}
      unknown = {:unknown, {Lib, :go, 0}, nil}

      assert Annotation.check({:impure, [io, unknown]}, [:io, :unknown]) == :ok
    end

    test "what is left decides the verdict, not what it started as" do
      io = {:io, {IO, :puts, 1}, nil}
      unknown = {:unknown, {Lib, :go, 0}, nil}

      assert Annotation.check({:impure, [io, unknown]}, [:io]) ==
               {:violation, {:unknown, [unknown]}}
    end

    test "a higher-order function keeps the claim" do
      assert Annotation.check({:conditional, [2]}, []) == :ok
    end

    test "a purity the analyser could not determine does not" do
      verdict = {:unknown, [{:dynamic_call, nil, nil}]}

      assert Annotation.check(verdict, []) == {:violation, verdict}
      assert Annotation.check(verdict, [:dynamic_call]) == :ok
    end
  end

  describe "stale/2" do
    test "a waiver the function does not need is reported" do
      assert Annotation.stale([], [:time]) == [:time]
    end

    test "a waiver the function needs is not" do
      assert Annotation.stale([{:time, {DateTime, :utc_now, 0}, nil}], [:time]) == []
    end
  end

  test "every effect class the analyser can report can be waived and described" do
    for category <- Pure.Knowledge.categories() do
      assert Annotation.parse(except: [category]) == {:ok, [category]}
      assert is_binary(Pure.Knowledge.describe(category))
    end
  end
end
