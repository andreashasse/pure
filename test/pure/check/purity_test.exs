defmodule Pure.Check.PurityTest do
  use Credo.Test.Case

  alias Pure.Check.Purity

  # Real files, because the check answers from compiled code: these are
  # both on disk and in the test build, the way a user's modules are.
  @waivers "test/support/waivers.ex"
  @pure_module "test/support/pure_module.ex"

  # Following calls into dependencies is the right default for a project
  # and pointless here: nothing the fixtures call lives in one.
  defp check(path, params \\ []) do
    path
    |> File.read!()
    |> to_source_file(path)
    |> run_check(Purity, Keyword.put_new(params, :follow_deps, false))
  end

  defp check_source(source, filename, params \\ []) do
    source
    |> to_source_file(filename)
    |> run_check(Purity, Keyword.put_new(params, :follow_deps, false))
  end

  defp messages(issues), do: Enum.map(issues, & &1.message)

  defp about(issues, subject) do
    Enum.filter(issues, &String.starts_with?(&1.message, subject))
  end

  describe "a file with nothing to say" do
    test "is left alone" do
      assert check("lib/pure/knowledge.ex") == []
    end
  end

  describe "@pure except: [...]" do
    setup do
      %{issues: check(@waivers)}
    end

    test "an effect the annotation owns up to is not a finding", %{issues: issues} do
      assert about(issues, "stamped/1") == []
    end

    test "an effect it did not own up to is", %{issues: issues} do
      assert [issue] = about(issues, "still_writes/1 is")

      assert issue.message ==
               "still_writes/1 is annotated @pure except: [:time] but is impure: " <>
                 "performs I/O (IO.puts/1)"
    end

    test "a waiver is not inherited by the caller", %{issues: issues} do
      assert [issue] = about(issues, "calls_a_waived_function/1")

      assert issue.message =~ "is annotated @pure but is impure: reads the clock"
      assert issue.message =~ "via Pure.Sample.Waivers.stamped/1"
    end

    test "a higher-order function keeps the claim", %{issues: issues} do
      assert about(issues, "hof/2") == []
    end

    test "purity the analyser could not determine can be waived like any effect", %{
      issues: issues
    } do
      assert about(issues, "unknowable/1") == []
    end

    test "the issue points at the function that made the claim", %{issues: issues} do
      [issue] = about(issues, "calls_a_waived_function/1")
      line = @waivers |> File.read!() |> String.split("\n") |> Enum.at(issue.line_no - 1)

      assert line =~ "def calls_a_waived_function"
    end

    test "a violation carries the whole reason list for a formatter", %{issues: issues} do
      [issue] = about(issues, "still_writes/1 is")

      assert [effects: [{:io, {IO, :puts, 1}, nil}]] = issue.meta
    end
  end

  describe "a waiver that has outlived its effect" do
    setup do
      %{issues: check(@waivers)}
    end

    test "is reported", %{issues: issues} do
      assert [issue] = about(issues, "outgrew_its_waiver/1")
      assert issue.message == "outgrew_its_waiver/1 waives :time, which it does not do"
    end

    test "cannot fail a build on its own", %{issues: issues} do
      [issue] = about(issues, "outgrew_its_waiver/1")

      assert issue.exit_status == 0
      assert issue.priority < 0
    end

    test "is reported next to the effect that was not waived", %{issues: issues} do
      assert "still_writes/1 waives :time, which it does not do" in messages(issues)
    end
  end

  describe "@pure_module" do
    setup do
      %{issues: check(@pure_module)}
    end

    test "covers a public function that never mentioned purity", %{issues: issues} do
      assert [issue] = about(issues, "writes/1")

      assert issue.message ==
               "writes/1 is covered by @pure_module except: [:time] but is impure: " <>
                 "performs I/O (IO.puts/1) via Pure.Sample.PureModule.shout/1"
    end

    test "waives the same class for every function it covers", %{issues: issues} do
      assert about(issues, "stamped/1") == []
      assert about(issues, "plain/2") == []
    end

    test "says nothing about private functions", %{issues: issues} do
      assert about(issues, "shout/1") == []
    end

    test "lets a function narrow what it waives", %{issues: issues} do
      assert about(issues, "narrowed/2") == []
    end

    test "does not let a function widen it", %{issues: issues} do
      assert [issue] = about(issues, "@pure on widened/1")

      assert issue.message ==
               "@pure on widened/1 waives :io, which its module's @pure_module does not"
    end

    test "a nested module does not inherit the waiver it is written inside", %{issues: issues} do
      assert [issue] = about(issues, "now_and_then/1")

      assert issue.message ==
               "now_and_then/1 is covered by @pure_module but is impure: " <>
                 "reads the clock (DateTime.utc_now/0)"
    end

    test "a waiver used by one function is not stale for the rest", %{issues: issues} do
      assert about(issues, "@pure_module on Pure.Sample.PureModule waives") == []
    end

    test "a module waiver nothing needs is reported once, against the module" do
      issues =
        check_source(
          """
          defmodule Pure.Sample.PureModule do
            @pure_module except: [:network]
            def plain(a, b), do: a + b
          end
          """,
          @pure_module
        )

      assert [issue] = about(issues, "@pure_module")

      assert issue.message ==
               "@pure_module on Pure.Sample.PureModule waives :network, " <>
                 "which nothing in the module does"

      assert issue.exit_status == 0
    end
  end

  describe "an annotation that is wrong in itself" do
    test "a misspelt effect class is named" do
      assert [issue] = problems("@pure except: [:tyme]")

      assert issue.message == "@pure on fee/1 waives :tyme, which is not an effect class"
    end

    test "@pure false says what to do instead" do
      assert [issue] = problems("@pure false")

      assert issue.message =~ "is set to `false`"
      assert issue.message =~ "credo:disable-for-next-line Pure.Check.Purity"
    end

    test "any other value is rejected" do
      assert [issue] = problems("@pure allow: [:time]")

      assert issue.message =~ "is set to `[allow: [:time]]`"
      assert issue.message =~ "neither `true` nor `except: [...]`"
    end

    test "it fails the build like any other finding" do
      assert [issue] = problems("@pure except: [:tyme]")

      assert issue.exit_status > 0
    end

    defp problems(annotation) do
      """
      defmodule Pure.Sample.PureModule do
        #{annotation}
        def fee(x), do: x
      end
      """
      |> check_source(@pure_module)
      |> about("@pure on")
    end
  end

  describe "code that cannot be checked" do
    test "a module that was never compiled is reported rather than passed" do
      issues =
        check_source(
          """
          defmodule Pure.Sample.NeverCompiled do
            @pure true
            def fee(x), do: x
          end
          """,
          "lib/never_compiled.ex"
        )

      assert [issue] = issues
      assert issue.message =~ "Pure.Sample.NeverCompiled claims purity"
      assert issue.message =~ "run mix compile"
      assert issue.exit_status > 0
    end

    test "an annotation that is wrong in itself is still reported" do
      issues =
        check_source(
          """
          defmodule Pure.Sample.NeverCompiled do
            @pure except: [:tyme]
            def fee(x), do: x
          end
          """,
          "lib/never_compiled.ex"
        )

      assert Enum.any?(messages(issues), &(&1 =~ "not an effect class"))
    end

    @tag :tmp_dir
    test "a source newer than the code it compiled to is not checked against the old code", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "waivers.ex")
      File.write!(path, File.read!(@waivers))

      assert [issue] = check(path)
      assert issue.message =~ "Pure.Sample.Waivers has changed since it was last compiled"
      assert issue.exit_status > 0
    end
  end

  describe "configuration" do
    test "the known map can be extended from .credo.exs" do
      source = """
      defmodule Pure.Sample.Waivers do
        @pure true
        def unknowable(path), do: :zip.list_dir(path)
      end
      """

      assert [issue] = check_source(source, @waivers)

      assert issue.message ==
               "unknowable/1 is annotated @pure but is unknown: calls a function the " <>
                 "analyser knows nothing about (:zip.list_dir/1)"

      assert check_source(source, @waivers, known: %{{:zip, :list_dir, 1} => :pure}) == []
    end
  end
end
