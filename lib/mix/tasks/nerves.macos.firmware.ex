defmodule Mix.Tasks.Nerves.Macos.Firmware do
  use Mix.Task
  @shortdoc "Builds a macOS VM containing the application release"
  @moduledoc """
  Builds a release and installs it into an isolated copy of the selected system.

      mix nerves.macos.firmware [--release NAME] [--output DIRECTORY]

  The output directory must not exist. Set NERVES_MACOS_PASSWORD for a guest
  whose development password differs from admin.
  """

  @impl true
  def run(args) do
    {options, positional} = OptionParser.parse!(args, strict: [release: :string, output: :string])
    if positional != [], do: Mix.raise("Unexpected arguments: #{inspect(positional)}")
    Mix.Task.run("nerves.precompile")
    config = Mix.Project.config()
    name = options[:release] || to_string(config[:default_release] || config[:app])
    Mix.Task.run("release", [name, "--overwrite"])
    release = Mix.Release.from_config!(String.to_existing_atom(name), config, [])

    destination =
      Path.expand(
        options[:output] || Path.join([Mix.Project.build_path(), "nerves", name <> ".macos"])
      )

    Nerves.System.MacOS.Firmware.build(
      release.path,
      System.fetch_env!("NERVES_SYSTEM"),
      destination,
      System.get_env("NERVES_MACOS_PASSWORD", "admin")
    )

    Mix.shell().info("macOS firmware: #{destination}")
  end
end
