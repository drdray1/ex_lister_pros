defmodule ExListerPros.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/drdray1/ex_lister_pros"

  def project do
    [
      app: :ex_lister_pros,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [threshold: 80, summary: [threshold: 80]],

      # Hex
      description: "Elixir client for pulling listings from ListerPros (Aryeo white-label)",
      package: package(),

      # Docs
      name: "ExListerPros",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExListerPros.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:floki, "~> 0.36"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.14", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md)
    ]
  end

  defp docs do
    [
      main: "ExListerPros",
      extras: ["README.md"],
      groups_for_modules: [
        API: [
          ExListerPros.Listings
        ],
        Session: [
          ExListerPros.Session,
          ExListerPros.Client
        ]
      ]
    ]
  end
end
