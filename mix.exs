defmodule OffBroadway.EMQTT.MixProject do
  nil
  use Mix.Project

  @version "0.1.0"
  @description "A MQTT connector based on emqtt for Broadway."
  @source_url "https://github.com/Intility/off_broadway_emqtt"

  def project do
    [
      app: :off_broadway_emqtt,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: @description,
      deps: deps(),
      package: [
        maintainers: ["Rolf Håvard Blindheim <rolf.havard.blindheim@intility.no>"],
        licenses: ["Apache-2.0"],
        links: %{GitHub: @source_url}
      ],
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        source_url: @source_url,
        extras: [
          "README.md",
          "Changelog.md",
          "LICENSE"
        ]
      ],
      dialyzer: [flags: [:underspecs, :unknown]],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:broadway, "~> 1.1"},
      {:emqtt, "~> 1.11"},
      {:cowlib, "~> 2.13", override: true},
      {:ex_doc, "~> 0.34.2", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: :dev},
      {:dialyxir, "~> 1.4", only: :dev},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
