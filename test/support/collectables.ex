defmodule Pure.Sample.Quiet do
  @moduledoc "A struct whose String.Chars implementation is pure."
  defstruct [:name]

  defimpl String.Chars do
    def to_string(quiet), do: quiet.name
  end
end

defmodule Pure.Sample.Loud do
  @moduledoc "A struct whose String.Chars implementation is not."
  defstruct [:name]

  defimpl String.Chars do
    def to_string(loud) do
      IO.puts("converting")
      loud.name
    end
  end
end

defmodule Pure.Sample.Dispatch do
  @moduledoc """
  Protocol dispatch, which is only as pure as the implementations it can
  reach.
  """

  def quiet(name), do: to_string(%Pure.Sample.Quiet{name: name})

  def loud(name), do: to_string(%Pure.Sample.Loud{name: name})

  def unknown_term(term), do: to_string(term)

  def into_map(list), do: for(x <- list, into: %{}, do: {x, x})
end
