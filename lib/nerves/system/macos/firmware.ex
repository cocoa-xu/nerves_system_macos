defmodule Nerves.System.MacOS.Firmware do
  @moduledoc false
  alias Nerves.System.MacOS.{Artifact, Command, Config, Files, Runtime, VM}

  def verify(path, password \\ "admin") do
    metadata = path |> Path.join("nerves-firmware.json") |> File.read!() |> Jason.decode!()
    unless metadata["format"] == 1, do: raise("Unsupported firmware format")
    system = metadata["system"]

    config =
      Config.new!(
        [
          base_image: Path.join(path, "firmware.tart"),
          macos_version: system["macos_version"],
          macos_build: system["macos_build"],
          otp_root: Path.join(path, "runtime"),
          otp_version: system["otp_version"],
          username: system["username"],
          password: password
        ],
        File.cwd!()
      )

    VM.with_copy(config.base_image, Path.dirname(path), fn vm ->
      for boot <- 1..2 do
        IO.puts("Verifying cold boot #{boot}/2")
        VM.verify(vm, config, path <> ".verify.log")
      end
    end)

    :ok
  end

  def build(release, system, destination, password \\ "admin") do
    Files.host!()
    Files.absent!(destination)
    metadata = Artifact.read!(system)

    release_metadata =
      release |> Path.join("nerves-release.json") |> File.read!() |> Jason.decode!()

    unless release_metadata["format"] == 1 and release_metadata["system"] == metadata,
      do: raise("Release and system artifact do not match")

    unless Regex.match?(~r/^[a-z][a-z0-9_]*$/, release_metadata["name"]),
      do: raise("Invalid release name")

    Runtime.validate!(release)

    config =
      Config.new!(
        [
          base_image: Path.join(system, "system.tart"),
          macos_version: metadata["macos_version"],
          macos_build: metadata["macos_build"],
          otp_root: Path.join(system, "runtime"),
          otp_version: metadata["otp_version"],
          username: metadata["username"],
          password: password
        ],
        File.cwd!()
      )

    staging = destination <> ".building-" <> Files.unique()
    File.mkdir_p!(staging)

    try do
      archive = Path.join(staging, "release.tar.gz")
      Command.run!("gtar", ["-czf", archive, "-C", release, "."], timeout: 300_000)

      VM.with_copy(config.base_image, Path.dirname(destination), fn vm ->
        VM.provision(vm, config, destination <> ".log", archive)
        VM.export(vm, Path.join(staging, "firmware.tart"))
      end)

      File.rm!(archive)
      Files.write_json(Path.join(staging, "nerves-firmware.json"), release_metadata)
      File.rename!(staging, destination)
    after
      File.rm_rf!(staging)
    end

    destination
  end
end
