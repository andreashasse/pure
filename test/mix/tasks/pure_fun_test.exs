defmodule Mix.Tasks.PureFunTest do
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
    Mix.Task.reenable("pure_fun")
    Mix.Tasks.PureFun.run(["--no-deps" | argv])
    drain()
  end

  # The task colours its verdicts when ANSI is on, which it is in a
  # terminal and is not in CI, so the escapes are dropped here rather
  # than written into every assertion.
  defp drain(lines \\ []) do
    receive do
      {:mix_shell, _kind, [line]} -> drain([line | lines])
    after
      0 -> lines |> Enum.reverse() |> Enum.join("\n") |> strip_ansi()
    end
  end

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  test "reports the functions of one module" do
    output = run(["PureFun.Sample"])

    assert output =~ "PureFun.Sample"
    assert output =~ "add/2"
    assert output =~ "writes/1"
  end

  test "a filter shows pure functions that the default report hides" do
    assert run(["PureFun.Sample.add/2"]) =~ ~r/add\/2\s+pure/
    refute run([]) =~ "add/2"
  end

  test "--all shows pure functions" do
    assert run(["--all"]) =~ ~r/add\/2\s+pure/
  end

  test "a function filter narrows to that function" do
    output = run(["PureFun.Sample.writes/1"])

    assert output =~ "writes/1"
    refute output =~ "add/2"
  end

  test "a filter can leave out the arity" do
    assert run(["PureFun.Sample.guarded"]) =~ "guarded/1"
  end

  test "the reason and the callee it came through are reported" do
    output = run(["PureFun.Sample.two_hops/1"])

    assert output =~ "performs I/O (IO.puts/1)"
    assert output =~ "via PureFun.Sample.one_hop/1"
  end

  test "higher-order functions are reported as conditional" do
    assert run(["PureFun.Sample.hof/2"]) =~ "pure if the fun given as argument 2 is pure"
  end

  test "a filter that matches nothing says so" do
    assert run(["NoSuchModule"]) =~ "No matching functions."
  end

  test "the summary counts every verdict" do
    output = run(["--all", "PureFun.Sample"])

    assert output =~ ~r/\d+ pure, \d+ conditional, \d+ impure, \d+ unknown \(\d+ functions\)/
  end

  test "private functions are left out unless asked for" do
    refute run(["--all", "PureFun.Analyzer"]) =~ "scan_function/3"
    assert run(["--all", "--private", "PureFun.Analyzer"]) =~ "scan_function/3"
  end

  test "--unknown surfaces functions whose purity could not be determined" do
    assert run(["--unknown", "PureFun.Sample"]) =~ "dynamic/2"
  end

  test "--check fails when an annotated function is not pure" do
    assert_raise Mix.Error, ~r/annotation\(s\) are not kept/, fn -> run(["--check"]) end

    assert drain() =~ "PureFun.Sample.annotated_but_impure/1 is annotated @pure_fun but is impure"
  end

  test "an unknown switch is rejected" do
    assert_raise OptionParser.ParseError, fn -> run(["--nonsense"]) end
  end

  test "an annotation is set apart from the verdict" do
    assert run(["PureFun.Sample.add/2"]) =~ ~r/add\/2\s+pure  \[@pure_fun\]/
  end

  test "a verdict with several origins lists them once, by class, below it" do
    output = run(["PureFun.Sample.interpolates/1"])

    assert output =~ ~r/interpolates\/1\s+impure\n/
    assert output =~ "performs I/O: IO.puts/1 via String.Chars.PureFun.Sample.Loud.to_string/1"

    assert output =~
             "calls a function decided at runtime: String.Chars.Date.to_string/1, " <>
               "String.Chars.DateTime.to_string/1"
  end

  test "unknown calls come with how to resolve them" do
    output = run(["PureFun.Sample.Waivers.unknowable/1"])

    assert output =~ "Run without --no-deps"
    assert output =~ "known:"
  end

  test "says what it is about to do and how long it took" do
    output = run(["PureFun.Sample"])

    assert output =~ "Analysing 1 module..."
    assert output =~ ~r/Analysed \d+ functions in [\d.]+ s\./
  end
end
