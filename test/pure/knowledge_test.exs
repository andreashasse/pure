defmodule Pure.KnowledgeTest do
  use ExUnit.Case, async: true

  alias Pure.Knowledge

  doctest Pure.Knowledge

  test "a module default applies to every function in it" do
    assert Knowledge.lookup(File, :read, 1) == {:impure, :file}
    assert Knowledge.lookup(File, :write, 2) == {:impure, :file}
  end

  test "a per-function entry beats the module default, in both directions" do
    assert Knowledge.lookup(Enum, :map, 2) == {:hof, [2]}
    assert Knowledge.lookup(Enum, :random, 1) == {:impure, :random}
    assert Knowledge.lookup(:os, :type, 0) == :pure
    assert Knowledge.lookup(:os, :cmd, 1) == {:impure, :system}
  end

  test "arity-specific entries beat any-arity ones" do
    assert Knowledge.lookup(:erlang, :exit, 1) == :pure
    assert Knowledge.lookup(:erlang, :exit, 2) == {:impure, :process}
  end

  test "erlang is pure apart from the listed BIFs" do
    assert Knowledge.lookup(:erlang, :element, 2) == :pure
    assert Knowledge.lookup(:erlang, :self, 0) == {:impure, :process}
  end

  test "exception callbacks inserted by raise/2 are pure" do
    assert Knowledge.lookup(SomeError, :exception, 1) == :pure
  end

  test "the exception heuristic does not override a known impure module" do
    assert Knowledge.lookup(File, :exception, 1) == {:impure, :file}
  end

  @categories [
    :io,
    :file,
    :network,
    :system,
    :time,
    :random,
    :process,
    :process_dictionary,
    :message,
    :message_receive,
    :ets,
    :persistent_term,
    :mutable_state,
    :code_loading,
    :port,
    :tracing,
    :dynamic_call,
    :higher_order,
    :unknown
  ]

  test "every effect category reads as a sentence" do
    for category <- @categories do
      assert is_binary(Knowledge.describe(category))
    end
  end

  test "a native implementation stub is not mistaken for a pure body" do
    assert Knowledge.lookup(:erlang, :nif_error, 1) == {:impure, :unknown}
  end

  test "higher_order_functions/0 exposes the argument positions" do
    hofs = Knowledge.higher_order_functions()

    assert hofs[{Enum, :map, 2}] == [2]
    assert hofs[{:lists, :foldl, 3}] == [1]
  end

  test "the elixir runtime helpers behind map access are pure" do
    assert Knowledge.lookup(:elixir_erl_pass, :no_parens_remote, 2) == :pure
    assert Knowledge.lookup(:elixir_erl_pass, :parens_map_field, 2) == :pure
  end
end
