defmodule Pure.Sample.Waivers do
  @moduledoc """
  Fixture for `@pure except: [...]` — functions that own up to an effect,
  and functions that own up to the wrong one.

  Compiled only in `:test`, and analysed through the real pipeline, so the
  tests read the annotations out of a beam file the way `mix pure` does.
  """

  use Pure

  @pure except: [:time]
  def stamped(x), do: {DateTime.utc_now(), x}

  # The waiver is kept, but nothing in the body needs it any more.
  @pure except: [:time]
  def outgrew_its_waiver(x), do: x * 2

  # Waives the clock, writes to the console: the effect it did not own up
  # to is the one that is reported.
  @pure except: [:time]
  def still_writes(x), do: IO.puts(x)

  # A waiver belongs to the function that wrote it. This one claims to do
  # nothing at all while calling a function that reads the clock.
  @pure true
  def calls_a_waived_function(x), do: stamped(x)

  @pure except: [:unknown]
  def unknowable(path), do: :zip.list_dir(path)

  # Higher-order rather than impure: whoever passes the fun answers for it.
  @pure true
  def hof(list, fun), do: Enum.map(list, fun)

  # Both arities the default argument produces are annotated.
  @pure except: [:io]
  def defaulted(x, prefix \\ "> "), do: IO.puts(prefix <> x)
end
