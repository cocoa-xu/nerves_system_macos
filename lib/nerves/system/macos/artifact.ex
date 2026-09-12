defmodule Nerves.System.MacOS.Artifact do
  @moduledoc false
  alias Nerves.System.MacOS.{Command, Files, Runtime, VM}
  @manifest "nerves-macos.json"

  def build(config, destination, _options \\ []) do
    Files.host!()
    Files.absent!(destination)
    staging = destination <> ".building-" <> Files.unique()
    File.mkdir_p!(staging)

    try do
      runtime = Runtime.stage(config.otp_root, Path.join(staging, "runtime"), config.otp_version)

      VM.with_copy(config.base_image, Path.dirname(destination), fn vm ->
        VM.provision(vm, config, destination <> ".log")
        VM.export(vm, Path.join(staging, "system.tart"))
      end)

      Files.write_json(Path.join(staging, @manifest), %{
        "format" => 1,
        "platform" => "macos",
        "architecture" => "arm64",
        "macos_version" => config.macos_version,
        "macos_build" => config.macos_build,
        "otp_version" => runtime.otp_version,
        "openssl" => runtime.openssl,
        "erts_version" => runtime.erts_version,
        "username" => config.username
      })

      File.rename!(staging, destination)
    after
      File.rm_rf!(staging)
    end
  end

  def read!(path) do
    manifest = Path.join(path, @manifest)
    Files.regular!(manifest)
    value = manifest |> File.read!() |> Jason.decode!()

    unless value["format"] == 1 and value["platform"] == "macos",
      do: raise("Unsupported system artifact")

    value
  end

  def archive(source, destination) do
    read!(source)
    Files.absent!(destination)
    File.mkdir_p!(Path.dirname(destination))
    temporary = destination <> ".partial-" <> Files.unique()

    try do
      Command.run!("gtar", ["--sparse", "-czf", temporary, "-C", source, "."], timeout: 3_600_000)
      File.rename!(temporary, destination)
    after
      File.rm(temporary)
    end
  end

  def clean(path) do
    if File.exists?(path) do
      unless match?({:ok, %{type: :directory}}, File.lstat(path)),
        do: raise("Refusing to clean a symlink or non-directory")

      read!(path)
      image = Path.join(path, "system.tart")
      if File.dir?(image), do: VM.validate!(image)
      File.rm_rf!(path)
    end
  end
end
