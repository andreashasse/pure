defmodule Pure.Sample.Formatter do
  @moduledoc "A behaviour with one pure and one impure implementation."
  @callback format(term()) :: String.t()
end

defmodule Pure.Sample.PlainFormatter do
  @behaviour Pure.Sample.Formatter

  @impl true
  def format(term), do: inspect(term)
end

defmodule Pure.Sample.LoggingFormatter do
  @behaviour Pure.Sample.Formatter

  @impl true
  def format(term) do
    IO.puts("formatting")
    inspect(term)
  end
end

defmodule Pure.Sample.Doubler do
  @moduledoc "A behaviour whose only implementation is pure."
  @callback double(integer()) :: integer()
end

defmodule Pure.Sample.TwiceDoubler do
  @behaviour Pure.Sample.Doubler

  @impl true
  def double(x), do: x * 2
end

defmodule Pure.Sample.BehaviourDispatch do
  @moduledoc """
  Calls that reach an implementation without naming it.
  """

  # The module is not known until runtime, but `format/1` is.
  def through_variable(module, term), do: module.format(term)

  def double_through_variable(module, x), do: module.double(x)

  # Naming the behaviour itself, the way a protocol call looks. The
  # function only exists on the implementations, which is exactly what
  # makes this a dispatch.
  @compile {:no_warn_undefined, {Pure.Sample.Formatter, :format, 1}}
  def through_behaviour(term), do: Pure.Sample.Formatter.format(term)
end
