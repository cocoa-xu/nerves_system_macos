defmodule NervesSystemMacOS.MixProject do
  use Mix.Project

  def project do
    [
      app: :nerves_system_macos,
      version: "0.1.0",
      elixir: "~> 1.16",
      description: "macOS system build platform for Nerves",
      nerves_package: [type: :system_platform],
      deps: [{:nerves, "~> 1.15", runtime: false}, {:jason, "~> 1.4"}],
      package: [
        files: ~w(lib priv mix.exs README.md LICENSE NOTICE CHANGELOG.md),
        licenses: ["Apache-2.0"],
        links: %{}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
