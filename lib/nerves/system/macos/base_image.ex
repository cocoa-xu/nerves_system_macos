defmodule Nerves.System.MacOS.BaseImage do
  @moduledoc """
  Downloads, restores and verifies macOS bases.
  """
  alias Nerves.System.MacOS.{BaseSpec, Command, Files, OCI, VM}

  def with_source(spec, root, work_root, fun) do
    BaseSpec.validate!(spec)
    host!(spec)
    source = spec["source"]

    if source["type"] == "local" do
      image = BaseSpec.path(source["path"], root)
      VM.validate!(image)

      for file <- BaseSpec.files(),
          do: verify_digest!(Path.join(image, file), source["sha256"][file])

      fun.(image)
    else
      VM.with_home(work_root, fn vm ->
        acquire(source, root, vm)
        VM.validate!(vm.path)
        fun.(vm.path)
      end)
    end
  end

  def prepare(spec_path, destination) do
    spec = BaseSpec.read!(spec_path)
    Files.absent!(destination)
    File.mkdir_p!(Path.dirname(destination))
    staging = destination <> ".building-" <> Files.unique()

    try do
      with_source(spec, Path.dirname(spec_path), Path.dirname(destination), fn source ->
        VM.with_copy(source, Path.dirname(destination), fn vm ->
          VM.verify_base(vm, guest_config(spec), destination <> ".log")
          VM.export(vm, staging)
        end)
      end)

      Files.write_json(Path.join(staging, "nerves-base.json"), provenance(spec))
      File.rename!(staging, destination)
    after
      File.rm_rf!(staging)
    end

    destination
  end

  def provenance(spec),
    do: %{
      "format" => 1,
      "fingerprint" => BaseSpec.fingerprint(spec),
      "macos" => spec["macos"],
      "source" => spec["source"]["type"]
    }

  def guest_config(spec),
    do: %{
      macos_version: spec["macos"]["version"],
      macos_build: spec["macos"]["build"],
      username: "admin",
      password: "admin"
    }

  def host!(spec) do
    Files.host!()

    host =
      Command.run!("sw_vers", ["-productVersion"])
      |> String.trim()
      |> String.split(".")
      |> hd()
      |> String.to_integer()

    if host < BaseSpec.major(spec),
      do: raise("The selected base requires macOS #{BaseSpec.major(spec)} or later on the host")
  end

  def verify_digest!(path, expected) do
    unless Files.sha256(path) == expected, do: raise("SHA-256 mismatch: #{path}")
  end

  def verify_checkout!(repository, revision) do
    env = %{"GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null"}
    options = [cd: repository, env: env, timeout: 30_000]
    actual = Command.run!("git", ["rev-parse", "HEAD"], options) |> String.trim()
    unless actual == revision, do: raise("The builder checkout revision does not match")
    Command.run!("git", ["diff", "--quiet", "HEAD", "--"], options)
    :ok
  end

  defp acquire(%{"type" => "prebuilt"} = source, _root, vm) do
    OCI.with_mirror(source, vm.session, fn reference ->
      {host, _, _} = BaseSpec.reference!(reference)

      env =
        Map.merge(vm.env, %{
          "TART_REGISTRY_HOSTNAME" => host,
          "TART_REGISTRY_USERNAME" => "unused",
          "TART_REGISTRY_PASSWORD" => "unused"
        })

      Command.run!("tart", ["clone", reference, vm.name, "--concurrency", "2", "--insecure"],
        env: env,
        timeout: 3_600_000,
        stream: true
      )
    end)
  end

  defp acquire(%{"type" => "build"} = source, root, vm) do
    executable = BaseSpec.path(source["executable"], root)
    repository = BaseSpec.path(source["repository"], root)
    verify_digest!(executable, source["sha256"])
    verify_checkout!(repository, source["revision"])

    arguments =
      Enum.map(source["arguments"], fn
        "{vm}" -> vm.name
        value -> value
      end)

    Command.run!(executable, arguments,
      cd: repository,
      env: vm.env,
      timeout: Map.get(source, "timeout_seconds", 3600) * 1000,
      stream: true
    )

    verify_checkout!(repository, source["revision"])
  end
end
