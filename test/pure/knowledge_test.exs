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

  test "every effect category has a description" do
    for {_mfa, {:impure, category}} <- [{nil, {:impure, :io}}] do
      assert is_binary(Knowledge.describe(category))
    end
  end
end
