defmodule Pure.Sample.PureModule do
  @moduledoc """
  Fixture for `@pure_module` — a whole module claimed as a functional
  core, with one waiver covering every function in it.

  Compiled only in `:test`, and analysed through the real pipeline.
  """

  use Pure

  @pure_module except: [:time]

  def stamped(x), do: {DateTime.utc_now(), x}

  def plain(a, b), do: a + b

  # Narrower than the module: allowed, and checked as written.
  @pure true
  def narrowed(a, b), do: a - b

  # Wider than the module: the widening is the finding, not the effect.
  @pure except: [:io]
  def widened(x), do: shout(x)

  # Covered by the module, and writing where the module allows only the
  # clock.
  def writes(x), do: shout(x)

  # Private, so the module's claim about its public interface says
  # nothing about it.
  defp shout(x), do: IO.puts(x)

  defmodule Strict do
    @moduledoc """
    A nested module with a claim of its own: the enclosing module's
    waiver has nothing to do with it.
    """

    use Pure

    @pure_module true

    def double(x), do: x * 2

    # The module a few lines up waives the clock. This one does not, so
    # the same body that passes out there is a violation in here.
    def now_and_then(x), do: {DateTime.utc_now(), x}
  end
end
