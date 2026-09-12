defmodule NervesSystemMacOSExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :nerves_system_macos_example,
      version: "0.1.0",
      compilers: Mix.compilers() ++ [:nerves_package],
      nerves_package: [
        type: :system,
        platform: Nerves.System.MacOS,
        build_runner: Nerves.Artifact.BuildRunners.Local,
        platform_config: [
          base_image: System.get_env("NERVES_MACOS_BASE"),
          otp_root: System.get_env("NERVES_MACOS_OTP_ROOT"),
          otp_version: "29.0.2",
          macos_version: "26.6.2",
          macos_build: "25G83"
        ],
        checksum: ["mix.exs"]
      ],
      aliases: [loadconfig: [&bootstrap/1]],
      deps: [
        {:nerves, "~> 1.15", runtime: false},
        {:nerves_system_macos, path: "../..", runtime: false}
      ]
    ]
  end

  defp bootstrap(args) do
    Mix.target(:macos)
    {:ok, _} = Application.ensure_all_started(:nerves_bootstrap)
    Mix.Task.run("loadconfig", args)
  end
end
