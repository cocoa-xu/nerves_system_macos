defmodule Nerves.System.MacOS.VM do
  @moduledoc false
  alias Nerves.System.MacOS.{Command, Files}

  def validate!(source) do
    for file <- ~w(config.json disk.img nvram.bin), do: Files.regular!(Path.join(source, file))
    config = source |> Path.join("config.json") |> File.read!() |> Jason.decode!()

    unless config["os"] == "darwin" and config["arch"] == "arm64" and
             config["diskFormat"] in [nil, "raw"],
           do: raise("Base image must be a standalone arm64 macOS raw disk bundle")

    for field <- ~w(hardwareModel ecid) do
      unless is_binary(config[field]) and match?({:ok, _}, Base.decode64(config[field])),
        do: raise("Base image is missing a valid #{field}")
    end

    closed!(Path.join(source, "disk.img"))
  end

  defp closed!(disk) do
    case Command.run!("/usr/sbin/lsof", ["-t", "--", disk],
           accept: [1],
           timeout: 20_000
         ) do
      "" -> :ok
      _ -> raise "The source disk is open; shut down its VM before building"
    end
  end

  def with_copy(source, work_root, fun) do
    validate!(source)
    session = Path.join(work_root, "session-" <> Files.unique())
    name = "nerves-macos-" <> Files.unique()
    home = Path.join(session, "tart")
    vm = Path.join([home, "vms", name])
    File.mkdir_p!(vm)
    env = %{"TART_HOME" => home, "TART_NO_AUTO_PRUNE" => "1", "CI" => "true"}

    try do
      for file <- ~w(config.json disk.img nvram.bin),
          do: Files.clone(Path.join(source, file), Path.join(vm, file))

      config_path = Path.join(vm, "config.json")
      config = config_path |> File.read!() |> Jason.decode!()

      mac =
        Enum.join(
          [
            "02"
            | for(<<byte <- :crypto.strong_rand_bytes(5)>>,
                do: Base.encode16(<<byte>>, case: :lower)
              )
          ],
          ":"
        )

      Files.write_json(config_path, Map.put(config, "macAddress", mac))

      fun.(%{name: name, path: vm, home: home, env: env, session: session})
    after
      Command.run!("tart", ["stop", name], env: env, timeout: 20_000, accept: [2])
      if File.exists?(Path.join(vm, "disk.img")), do: closed!(Path.join(vm, "disk.img"))
      File.rm_rf!(session)
    end
  end

  def provision(vm, config, log, release \\ nil) do
    extra =
      if release,
        do:
          File.read!(Files.priv("guest/install-release.sh")) <>
            "\n" <> File.read!(Files.priv("guest/verify-release.sh")),
        else: ""

    run(vm, config, log, extra, release)
  end

  def verify(vm, config, log) do
    run(vm, config, log, File.read!(Files.priv("guest/verify-release.sh")), nil)
  end

  defp run(vm, config, log, extra, release) do
    script = Path.join(vm.session, "provision.sh")
    body = File.read!(Files.priv("guest/verify-system.sh"))
    File.write!(script, body <> "\n" <> extra)

    env =
      Map.merge(vm.env, %{
        "SSHPASS" => config.password,
        "GUEST_USERNAME" => config.username,
        "EXPECTED_VERSION" => config.macos_version,
        "EXPECTED_BUILD" => config.macos_build
      })

    Command.run!(
      "/bin/bash",
      [Files.priv("scripts/provision.sh"), vm.name, vm.session, script, release || ""],
      env: env,
      timeout: 900_000,
      log: log,
      stream: true
    )
  end

  def export(vm, destination) do
    validate!(vm.path)
    Files.absent!(destination)
    File.mkdir_p!(destination)

    for file <- ~w(config.json disk.img nvram.bin),
        do: Files.clone(Path.join(vm.path, file), Path.join(destination, file))
  end
end
