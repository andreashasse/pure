defmodule Pure.Sample do
  @moduledoc """
  Fixture covering the cases the analyser is supposed to get right.

  Compiled only in `:test`, and analysed through the real pipeline —
  beam file, abstract code, fixpoint — so the tests exercise what users
  actually run.
  """

  use Pure

  ## Plainly pure

  @pure true
  def add(a, b), do: a + b

  def double_all(list), do: Enum.map(list, fn x -> x * 2 end)

  def capture_pure(list), do: Enum.map(list, &String.upcase/1)

  def via_pure_local(list), do: double_all(list) ++ [0]

  def guarded(x) when is_integer(x) and x > 0, do: :positive
  def guarded(_), do: :other

  def comprehension(list), do: for(x <- list, x > 1, do: x * x)

  def recursive([]), do: 0
  def recursive([head | tail]), do: head + recursive(tail)

  def mutually_recursive_a(0), do: :done
  def mutually_recursive_a(n), do: mutually_recursive_b(n - 1)

  def mutually_recursive_b(n), do: mutually_recursive_a(n)

  def raises(_x), do: raise(ArgumentError, "no")

  def interpolates(x), do: "value: #{x}"

  def interpolates_integer, do: "value: #{1}"

  def structs(list), do: Map.new(list, fn {k, v} -> {k, v} end)

  ## Plainly impure

  @pure true
  def annotated_but_impure(x), do: IO.puts(x)

  def writes(x), do: IO.puts(x)

  def sends(pid), do: send(pid, :ping)

  def receives do
    receive do
      msg -> msg
    end
  end

  def process_dictionary(x), do: Process.put(:key, x)

  def reads_clock, do: DateTime.utc_now()

  def spawns(fun), do: spawn(fun)

  def table(name), do: :ets.lookup(name, :key)

  ## Impure through the call graph

  def one_hop(x), do: writes(x)

  def two_hops(x), do: one_hop(x)

  def impure_capture(list), do: Enum.each(list, &IO.puts/1)

  def impure_inline_fun(list), do: Enum.map(list, fn x -> IO.inspect(x) end)

  ## Higher-order

  def hof(list, fun), do: Enum.map(list, fun)

  def applies(fun), do: fun.(1)

  def passes_through(list, fun), do: hof(list, fun)

  def hof_with_pure_fun(list), do: hof(list, &String.upcase/1)

  def hof_with_impure_fun(list), do: hof(list, &IO.puts/1)

  def two_position_hof(list, chunk, after_fun) do
    Enum.chunk_while(list, [], chunk, after_fun)
  end

  def literal_at_hof_position(list), do: Enum.with_index(list, 1)

  def bound_fun(list) do
    double = fn x -> x * 2 end
    Enum.map(list, double)
  end

  def bound_impure_fun(list) do
    log = fn x -> IO.puts(x) end
    Enum.each(list, log)
  end

  def with_else(map) do
    with {:ok, value} <- Map.fetch(map, :key) do
      value
    else
      :error -> :missing
    end
  end

  def with_else_impure(map) do
    with {:ok, value} <- Map.fetch(map, :key) do
      value
    else
      :error -> IO.puts("missing")
    end
  end

  def then_pipe(x), do: then(x, fn value -> value + 1 end)

  def for_into(list), do: for(x <- list, into: %{}, do: {x, x})

  def try_rescue(fun) do
    fun.()
  rescue
    error -> Exception.message(error)
  end

  def receive_after do
    receive do
      msg -> msg
    after
      100 -> :timeout
    end
  end

  ## Unknown

  def dynamic(module, fun), do: apply(module, fun, [])

  def dynamic_module(module), do: module.run()

  def unresolvable_fun(map), do: map.fun.(1)
end
