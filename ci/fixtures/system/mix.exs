defmodule NervesSystemMacOSSelected.MixProject do
  use Mix.Project

  def project do
    spec = "bases/#{Mix.target()}.json"

    [
      app: :nerves_system_macos_selected,
      version: "0.1.0",
      compilers: Mix.compilers() ++ [:nerves_package],
      nerves_package: [
        type: :system,
        platform: Nerves.System.MacOS,
        build_runner: Nerves.Artifact.BuildRunners.Local,
        platform_config: [
          base_spec: spec,
          otp_root: System.get_env("NERVES_MACOS_OTP_ROOT"),
          otp_version: "29.0.2"
        ],
        checksum: ["mix.exs", spec]
      ],
      aliases: [loadconfig: [&bootstrap/1]],
      deps: [
        {:nerves, "~> 1.15", runtime: false},
        {:nerves_system_macos, path: "../../..", runtime: false}
      ]
    ]
  end

  defp bootstrap(args) do
    {:ok, _} = Application.ensure_all_started(:nerves_bootstrap)
    Mix.Task.run("loadconfig", args)
  end
end
