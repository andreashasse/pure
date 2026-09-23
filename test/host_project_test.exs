defmodule PureFun.HostProjectTest do
  @moduledoc """
  Builds a project that depends on this library the way a user's would,
  and checks what only shows up from the outside: that the Credo check
  is compiled whatever order Mix builds dependencies in, and that
  `use PureFun` compiles in `:prod`.

  Excluded by default because it compiles a project from scratch: run it
  with `mix test --include host_project`. It reuses this repository's
  `deps` directory and lock, so it needs no network.
  """

  use ExUnit.Case, async: false

  @moduletag :host_project
  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  @root Path.expand("..", __DIR__)

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Host.MixProject do
      use Mix.Project

      def project do
        [
          app: :host,
          version: "0.1.0",
          deps_path: #{inspect(Path.join(@root, "deps"))},
          deps: [
            {:pure_fun, path: #{inspect(@root)}, runtime: false},
            {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
          ]
        ]
      end
    end
    """)

    File.cp!(Path.join(@root, "mix.lock"), Path.join(dir, "mix.lock"))

    File.write!(Path.join(dir, ".credo.exs"), """
    %{configs: [%{name: "default", checks: %{enabled: [{PureFun.Check.Purity, []}]}}]}
    """)

    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "lib/host.ex"), """
    defmodule Host do
      use PureFun

      @pure_fun true
      def greet(name), do: IO.puts("hello " <> name)
    end
    """)

    :ok
  end

  defp mix(dir, args, env) do
    System.cmd("mix", args, cd: dir, env: [{"MIX_ENV", env}], stderr_to_stdout: true)
  end

  test "the Credo check is compiled even when pure_fun is built on its own", %{tmp_dir: dir} do
    assert {_output, 0} = mix(dir, ["compile"], "dev")

    # Building pure_fun alone is what exposed a missing dependency on
    # Credo: nothing else put Credo on the code path first.
    assert {_output, 0} = mix(dir, ["deps.compile", "pure_fun", "--force"], "dev")

    assert File.exists?(
             Path.join(dir, "_build/dev/lib/pure_fun/ebin/Elixir.PureFun.Check.Purity.beam")
           )

    {output, _status} = mix(dir, ["credo", "--strict"], "dev")

    refute output =~ "undefined check"
    assert output =~ "greet/1 is annotated @pure_fun but is impure"
  end

  test "a project using PureFun compiles in prod", %{tmp_dir: dir} do
    assert {_output, 0} = mix(dir, ["compile"], "prod")
  end
end
