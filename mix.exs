defmodule PureFun.MixProject do
  use Mix.Project

  def project do
    [
      app: :pure_fun,
      version: "0.1.1",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_paths: erlc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Fixtures are read as compiled code, never run, so coverage of
      # them means nothing.
      test_coverage: [
        ignore_modules: [
          ~r/^(Elixir\.)?PureFun\.Sample/,
          ~r/PureFun\.Sample/,
          :pure_sample_erl,
          :pure_module_erl
        ]
      ],
      description: "Static purity analysis for BEAM functions",
      package: package(),
      name: "PureFun",
      source_url: "https://github.com/andreashasse/pure_fun",
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp erlc_paths(:test), do: ["test/erlang"]
  defp erlc_paths(_), do: []

  # Credo is optional on purpose: `PureFun.Check.Purity` is only compiled
  # when the project using this library has Credo of its own, so a
  # build-time analysis tool everyone is expected to add to their project
  # still drags nothing in.
  #
  # It must not say `only:`. The host project ignores the `only:`
  # dependencies of a dependency, so Credo would then not be built before
  # this library, and the check would be compiled or not by luck.
  defp deps do
    [
      {:credo, "~> 1.7", optional: true, runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/andreashasse/pure_fun"},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE.md)
    ]
  end
end
