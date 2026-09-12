defmodule Mix.Tasks.Nerves.Macos.Verify do
  use Mix.Task
  @shortdoc "Verifies a firmware bundle through two cold boots of a temporary copy"
  @impl true
  def run([path]) do
    Nerves.System.MacOS.Firmware.verify(
      Path.expand(path),
      System.get_env("NERVES_MACOS_PASSWORD", "admin")
    )

    Mix.shell().info("Both cold boots passed")
  end

  def run(_), do: Mix.raise("Usage: mix nerves.macos.verify FIRMWARE_DIRECTORY")
end
