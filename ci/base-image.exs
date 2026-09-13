defmodule BaseImageCI do
  alias Nerves.System.MacOS.{BaseImage, BaseSpec, Command, Files, HTTP}

  def check do
    {profile, runner, versions} = inputs!()
    ca = System.fetch_env!("NERVES_MACOS_CACERT")
    unless File.regular?(ca), do: raise("Expected an explicit PEM CA bundle")

    free =
      Command.run!("/bin/df", ["-Pk", System.fetch_env!("RUNNER_TEMP")])
      |> String.split("\n", trim: true)
      |> List.last()
      |> String.split()
      |> Enum.at(3)
      |> String.to_integer()

    if free < 100 * 1024 * 1024, do: raise("A base build requires at least 100 GiB free")
    IO.puts("Builder, tools, PEM bundle and disk space are ready")
    {profile, runner, versions}
  end

  def run do
    inputs = check()
    root = work_root()
    Files.absent!(root)
    File.mkdir_p!(root)
    File.write!(Path.join(root, ".ci-run"), run_id())
    logs = Path.expand(".nerves/ci-logs")
    File.mkdir_p!(logs)

    try do
      build(root, logs, inputs)
    after
      cleanup()
    end
  end

  def cleanup do
    root = work_root()

    if File.exists?(root) do
      unless File.read!(Path.join(root, ".ci-run")) == run_id(),
        do: raise("The work directory belongs to another run")

      for path <- Path.wildcard(Path.join(root, "**/tart/vms/*"), match_dot: true) do
        Command.run!("tart", ["stop", Path.basename(path)],
          env: %{
            "TART_HOME" => path |> Path.dirname() |> Path.dirname(),
            "TART_NO_AUTO_PRUNE" => "1"
          },
          timeout: 20_000,
          accept: [2]
        )
      end

      for disk <- Path.wildcard(Path.join(root, "**/disk.img"), match_dot: true) do
        unless Command.run!("/usr/sbin/lsof", ["-t", "--", disk], accept: [1], timeout: 20_000) ==
                 "",
               do: raise("A CI disk is still open: #{disk}")
      end

      File.rm_rf!(root)
      IO.puts("Removed this run's VMs, downloads and build outputs")
    end
  end

  defp inputs! do
    Files.host!()
    profile = "ci/macos15.json" |> File.read!() |> Jason.decode!()

    config_path =
      System.get_env(
        "NERVES_MACOS_RUNNER_CONFIG",
        Path.expand("~/.config/nerves-system-macos/runner.json")
      )

    runner = config_path |> File.read!() |> Jason.decode!()
    executable = Map.fetch!(runner, "executable")
    BaseImage.verify_digest!(executable, Map.fetch!(runner, "sha256"))
    BaseImage.verify_checkout!(runner["repository"], profile["builder_revision"])
    versions = tools!()

    unless hd(String.split(profile["otp"]["version"], ".")) == System.otp_release(),
      do: raise("The host OTP major must match the selected runtime")

    {profile, runner, versions}
  end

  defp build(root, logs, {profile, runner, versions}) do
    executable = runner["executable"]
    Files.write_json(Path.join(logs, "inputs.json"), Map.put(profile, "tools", versions))

    repository = Path.join(root, "builder")

    Command.run!("git", [
      "clone",
      "--local",
      "--no-hardlinks",
      "--no-checkout",
      runner["repository"],
      repository
    ])

    Command.run!(
      "git",
      ["-c", "core.hooksPath=/dev/null", "checkout", "--detach", profile["builder_revision"]],
      cd: repository
    )

    BaseImage.verify_checkout!(repository, profile["builder_revision"])

    ipsw = Path.join(root, "restore.ipsw")
    IO.puts("Downloading and checking macOS #{profile["macos"]["version"]} IPSW")

    download =
      HTTP.download(profile["ipsw"]["url"], ipsw,
        cacert: System.fetch_env!("NERVES_MACOS_CACERT"),
        max_bytes: profile["ipsw"]["size"],
        deadline: System.monotonic_time(:millisecond) + 1_800_000
      )

    unless download.status == 200 and download.size == profile["ipsw"]["size"] and
             download.sha256 == profile["ipsw"]["sha256"],
           do: raise("The IPSW size or SHA-256 does not match")

    recipe = Path.join(repository, profile["recipe"])
    contents = File.read!(recipe)
    expected = "IPSW_URL=#{profile["ipsw"]["url"]}\n"
    unless String.contains?(contents, expected), do: raise("The builder recipe uses another IPSW")
    local_recipe = Path.join(root, "image.env")

    File.write!(
      local_recipe,
      String.replace(contents, expected, "IPSW_URL='#{String.replace(ipsw, "'", "'\\''")}'\n")
    )

    spec =
      BaseSpec.validate!(%{
        "format" => 1,
        "image_version" => profile["image_version"],
        "macos" => profile["macos"],
        "source" => %{
          "type" => "build",
          "executable" => executable,
          "sha256" => runner["sha256"],
          "repository" => repository,
          "revision" => profile["builder_revision"],
          "timeout_seconds" => 3600,
          "arguments" => [
            "build",
            "vanilla",
            "--repository",
            repository,
            "--config",
            local_recipe,
            "--target",
            "{vm}"
          ]
        }
      })

    spec_path = Path.join(root, "base.json")
    Files.write_json(spec_path, spec)
    base = Path.join(root, "base.tart")
    IO.puts("Building and cold-booting the blank base")
    BaseImage.prepare(spec_path, base)
    File.cp!(base <> ".log", Path.join(logs, "base-guest.log"))
    File.cp!(Path.join(base, "nerves-base.json"), Path.join(logs, "base.json"))
    File.rm!(ipsw)

    project = Path.join(root, "project")
    File.mkdir!(project)
    archive = Path.join(root, "source.tar")
    Command.run!("git", ["archive", "--output", archive, "HEAD"])
    Command.run!("gtar", ["-xf", archive, "-C", project])
    File.rm!(archive)

    otp = Path.join(root, "otp")

    Command.run!(
      "mix",
      [
        "nerves.macos.otp",
        "--version",
        profile["otp"]["version"],
        "--sha256",
        profile["otp"]["sha256"],
        "--output",
        otp,
        "--cacert",
        System.fetch_env!("NERVES_MACOS_CACERT")
      ],
      timeout: 600_000,
      stream: true
    )

    selected_spec = Path.join(project, "examples/selectable_system/bases/macos15.json")

    Command.run!(
      "mix",
      [
        "nerves.macos.base",
        "lock",
        "--macos",
        "15",
        "--image-version",
        profile["image_version"],
        "--source",
        "local",
        "--image",
        base,
        "--output",
        selected_spec
      ],
      timeout: 900_000,
      stream: true
    )

    File.cp!(Path.join(project, "mix.lock"), Path.join(project, "examples/hello/mix.lock"))

    env = %{
      "MIX_TARGET" => "macos15",
      "NERVES_ARTIFACTS_DIR" => Path.join(root, "artifacts"),
      "NERVES_MACOS_OTP_ROOT" => Path.join(otp, "usr/local/lib/erlang")
    }

    hello = Path.join(project, "examples/hello")

    Command.run!("mix", ["deps.get", "--check-locked"],
      cd: hello,
      env: env,
      timeout: 300_000,
      stream: true
    )

    firmware = Path.join(root, "firmware")

    Command.run!("mix", ["firmware", "--output", firmware],
      cd: hello,
      env: env,
      timeout: 1_800_000,
      stream: true
    )

    File.cp!(firmware <> ".log", Path.join(logs, "firmware-guest.log"))
    Command.run!("mix", ["nerves.macos.verify", firmware], timeout: 900_000, stream: true)
    File.cp!(firmware <> ".verify.log", Path.join(logs, "two-boots.log"))
    File.cp!(Path.join(firmware, "nerves-firmware.json"), Path.join(logs, "firmware.json"))

    Files.write_json(Path.join(logs, "result.json"), %{
      "result" => "passed",
      "macos" => profile["macos"],
      "image_version" => profile["image_version"],
      "revision" => System.fetch_env!("GITHUB_SHA"),
      "run_id" => run_id()
    })

    IO.puts("macOS 15 passed a clean base build, Nerves firmware build and two cold boots")
  end

  defp tools! do
    checks = [
      {"tart", ["--version"], "2.36.0"},
      {"packer", ["--version"], "Packer v1.16.0"},
      {"go", ["version"], "go version go1.25.0 darwin/arm64"}
    ]

    versions =
      Map.new(checks, fn {command, args, expected} ->
        actual = Command.run!(command, args) |> String.trim()
        unless actual == expected, do: raise("Expected #{expected}, found #{actual}")
        {command, actual}
      end)

    plugins = Command.run!("packer", ["plugins", "installed"])

    unless String.contains?(plugins, "packer-plugin-tart_v1.21.0_x5.0_darwin_arm64"),
      do: raise("Install Tart Packer plugin 1.21.0 before starting CI")

    Map.merge(versions, %{
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "packer_tart" => "1.21.0"
    })
  end

  defp work_root, do: Path.join(System.fetch_env!("RUNNER_TEMP"), "nerves-macos-" <> run_id())

  defp run_id do
    value = System.fetch_env!("GITHUB_RUN_ID") <> "-" <> System.fetch_env!("GITHUB_RUN_ATTEMPT")
    unless Regex.match?(~r/\A\d+-\d+\z/, value), do: raise("Expected a GitHub Actions run ID")
    value
  end
end

case System.argv() do
  [] -> BaseImageCI.run()
  ["check"] -> BaseImageCI.check()
  ["cleanup"] -> BaseImageCI.cleanup()
  _ -> raise "Usage: mix run ci/base-image.exs [check|cleanup]"
end
