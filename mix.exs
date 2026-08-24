defmodule Pure.MixProject do
  use Mix.Project

  def project do
    [
      app: :pure,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_paths: erlc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Fixtures are read as compiled code, never run, so coverage of
      # them means nothing.
      test_coverage: [
        ignore_modules: [
          ~r/^(Elixir\.)?Pure\.Sample/,
          ~r/Pure\.Sample/,
          :pure_sample_erl,
          :pure_module_erl
        ]
      ],
      description: "Static purity analysis for BEAM functions",
      package: package(),
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp erlc_paths(:test), do: ["test/erlang"]
  defp erlc_paths(_), do: []

  # Credo is optional on purpose: `Pure.Check.Purity` is only compiled
  # when the project using this library has Credo of its own, so a
  # build-time analysis tool everyone is expected to add to their project
  # still drags nothing in.
  defp deps do
    [{:credo, "~> 1.7", optional: true, only: [:dev, :test], runtime: false}]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/andreashasse/pure"}
    ]
  end
end
