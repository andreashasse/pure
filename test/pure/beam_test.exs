defmodule Pure.BeamTest do
  use ExUnit.Case, async: true

  alias Pure.Beam

  test "loads a module by name" do
    assert {%{Pure.Sample => forms}, []} = Beam.load([Pure.Sample])
    assert Enum.any?(forms, &match?({:function, _, :add, 2, _}, &1))
  end

  test "loads an Erlang module by name" do
    assert {%{:pure_sample_erl => forms}, []} = Beam.load([:pure_sample_erl])
    assert Enum.any?(forms, &match?({:function, _, :add, 2, _}, &1))
  end

  test "loads every beam in a directory" do
    {forms, _skipped} = Beam.load([Mix.Project.compile_path()])

    assert Map.has_key?(forms, Pure.Analyzer)
    assert Map.has_key?(forms, Pure.Sample)
  end

  test "loads a single beam file by path" do
    path = Path.join(Mix.Project.compile_path(), "Elixir.Pure.Sample.beam")

    assert {%{Pure.Sample => _}, []} = Beam.load([path])
  end

  test "ignores paths that are not beams" do
    assert Beam.load(["mix.exs"]) == {%{}, []}
  end

  test "reports a module that does not exist" do
    assert {%{}, [{NoSuchModule, :not_found}]} = Beam.load([NoSuchModule])
  end

  test "reports a preloaded module as unreadable rather than skipping it silently" do
    assert {%{}, [{:erlang, :no_debug_info}]} = Beam.load([:erlang])
  end

  test "the same target twice is loaded once" do
    assert {forms, []} = Beam.load([Pure.Sample, Pure.Sample])
    assert map_size(forms) == 1
  end

  test "failures do not stop the rest from loading" do
    assert {forms, [{NoSuchModule, :not_found}]} = Beam.load([NoSuchModule, Pure.Sample])
    assert Map.has_key?(forms, Pure.Sample)
  end

  @tag :tmp_dir
  test "a file that is not really a beam is reported, not crashed on", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "broken.beam")
    File.write!(path, "not a beam file")

    assert {%{}, [{^path, reason}]} = Beam.load([path])
    assert reason != nil
  end

  @tag :tmp_dir
  test "a module compiled without debug_info cannot be analysed", %{tmp_dir: tmp_dir} do
    source = ~c"-module(no_debug).\n-export([f/0]).\nf() -> ok.\n"
    {:ok, tokens, _} = :erl_scan.string(source)

    forms =
      tokens
      |> split_forms()
      |> Enum.map(fn form -> elem(:erl_parse.parse_form(form), 1) end)

    {:ok, :no_debug, binary} = :compile.forms(forms, [])
    path = Path.join(tmp_dir, "no_debug.beam")
    File.write!(path, binary)

    assert {%{}, [{:no_debug, :no_debug_info}]} = Beam.load([path])
  end

  defp split_forms(tokens) do
    tokens
    |> Enum.chunk_by(&match?({:dot, _}, &1))
    |> Enum.chunk_every(2)
    |> Enum.map(&List.flatten/1)
    |> Enum.reject(&match?([{:dot, _}], &1))
  end

  test "build_dirs points at the project's compiled beams" do
    assert Beam.build_dirs() == [Mix.Project.compile_path()]
  end

  test "build_dirs with deps covers every application in the build" do
    dirs = Beam.build_dirs(deps: true)

    assert Enum.all?(dirs, &File.dir?/1)
    assert Enum.any?(dirs, &(Path.basename(Path.dirname(&1)) == "pure"))
  end
end
