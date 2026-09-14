defmodule HelloMacOS.MixProject do
  use Mix.Project

  def project do
    [
      app: :hello_macos,
      version: "0.1.0",
      elixir: "~> 1.16",
      compilers: [:elixir_make] ++ Mix.compilers(),
      aliases: [loadconfig: [&bootstrap/1], firmware: ["nerves.macos.firmware"]],
      releases: [hello_macos: &Nerves.System.MacOS.Release.options/0],
      deps: [
        {:nerves, "~> 1.15", runtime: false},
        {:elixir_make, "~> 0.10", runtime: false},
        {:nerves_system_macos_selected,
         path: "../system", targets: [:macos15, :macos26, :macos27], runtime: false}
      ]
    ]
  end

  def application do
    [mod: {HelloMacOS.Application, []}, extra_applications: [:logger, :crypto, :ssl]]
  end

  defp bootstrap(args) do
    {:ok, _} = Application.ensure_all_started(:nerves_bootstrap)
    Mix.Task.run("loadconfig", args)
  end
end
