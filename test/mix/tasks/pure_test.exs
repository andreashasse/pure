defmodule Mix.Tasks.PureTest do
  # Mix.shell/1 is global state, so these cannot run alongside anything
  # else that reports through it.
  use ExUnit.Case, async: false

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    :ok
  end

  # These are about what the task reports, not about how far it follows a
  # call graph, and reading every dependency's beam files for each of them
  # costs more than the rest of the suite put together.
  defp run(argv) do
    Mix.Task.reenable("pure")
    Mix.Tasks.Pure.run(["--no-deps" | argv])
    drain()
  end

  defp drain(lines \\ []) do
    receive do
      {:mix_shell, _kind, [line]} -> drain([line | lines])
    after
      0 -> lines |> Enum.reverse() |> Enum.join("\n")
    end
  end

  test "reports the functions of one module" do
    output = run(["Pure.Sample"])

    assert output =~ "Pure.Sample"
    assert output =~ "add/2"
    assert output =~ "writes/1"
  end

  test "a filter shows pure functions that the default report hides" do
    assert run(["Pure.Sample.add/2"]) =~ ~r/add\/2\s+pure/
    refute run([]) =~ "add/2"
  end

  test "--all shows pure functions" do
    assert run(["--all"]) =~ ~r/add\/2\s+pure/
  end

  test "a function filter narrows to that function" do
    output = run(["Pure.Sample.writes/1"])

    assert output =~ "writes/1"
    refute output =~ "add/2"
  end

  test "a filter can leave out the arity" do
    assert run(["Pure.Sample.guarded"]) =~ "guarded/1"
  end

  test "the reason and the callee it came through are reported" do
    output = run(["Pure.Sample.two_hops/1"])

    assert output =~ "performs I/O (IO.puts/1)"
    assert output =~ "via Pure.Sample.one_hop/1"
  end

  test "higher-order functions are reported as conditional" do
    assert run(["Pure.Sample.hof/2"]) =~ "pure if the fun given as argument 2 is pure"
  end

  test "a filter that matches nothing says so" do
    assert run(["NoSuchModule"]) =~ "No matching functions."
  end

  test "the summary counts every verdict" do
    output = run(["--all", "Pure.Sample"])

    assert output =~ ~r/\d+ pure, \d+ conditional, \d+ impure, \d+ unknown \(\d+ functions\)/
  end

  test "private functions are left out unless asked for" do
    refute run(["--all", "Pure.Analyzer"]) =~ "scan_module/2"
    assert run(["--all", "--private", "Pure.Analyzer"]) =~ "scan_module/2"
  end

  test "--unknown surfaces functions whose purity could not be determined" do
    assert run(["--unknown", "Pure.Sample"]) =~ "dynamic/2"
  end

  test "--check fails when an annotated function is not pure" do
    assert_raise Mix.Error, ~r/annotation\(s\) are not kept/, fn -> run(["--check"]) end

    assert drain() =~ "Pure.Sample.annotated_but_impure/1 is annotated @pure but is impure"
  end

  test "an unknown switch is rejected" do
    assert_raise OptionParser.ParseError, fn -> run(["--nonsense"]) end
  end
end
