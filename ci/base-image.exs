Code.require_file("publish.exs", __DIR__)
Code.require_file("verified-base.exs", __DIR__)

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
    Mix.shell().info("Builder, tools, PEM bundle and disk space are ready")
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

    build(root, logs, inputs)
  end

  def export do
    root = work_root()

    unless File.read!(Path.join(root, ".ci-run")) == run_id(),
      do: raise("The work directory belongs to another run")

    logs = Path.expand(".nerves/ci-logs")
    result = Path.join(logs, "result.json") |> File.read!() |> Jason.decode!()

    if verified_run() == "" do
      unless result["result"] == "passed" and
               result["revision"] == System.fetch_env!("GITHUB_SHA") and
               result["run_id"] == run_id(),
             do: raise("The current run must pass before publishing")

      VerifiedBase.save(Path.join(root, "base.tart"), logs, result)
    else
      unless File.read!(Path.join(root, ".verified-run")) == verified_run() and
               result["run_id"] == verified_run(),
             do: raise("The saved CI base must be verified before publishing")
    end

    BaseImagePublication.prepare(
      Path.join(root, "base.tart"),
      profile!(),
      result["revision"],
      root,
      logs
    )
  end

  def verify_publication do
    root = work_root()

    unless File.read!(Path.join(root, ".ci-run")) == run_id(),
      do: raise("The work directory belongs to another run")

    logs = Path.expand(".nerves/ci-logs")
    BaseImagePublication.verify(root, logs)
    result = Path.join(logs, "result.json") |> File.read!() |> Jason.decode!()
    VerifiedBase.remove(result)
  end

  def restore do
    root = work_root()
    Files.absent!(root)
    File.mkdir_p!(root)
    File.write!(Path.join(root, ".ci-run"), run_id())
    logs = Path.expand(".nerves/ci-logs")
    File.mkdir_p!(logs)
    VerifiedBase.restore(profile!(), verified_run(), root, logs)
    File.write!(Path.join(root, ".verified-run"), verified_run())
  end

  def check_publication, do: BaseImagePublication.check(profile!())

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
      Mix.shell().info("Removed this run's VMs, downloads and build outputs")
    end
  end

  defp inputs! do
    System.put_env("PACKER_CONFIG", Path.expand("ci/packer.json"))
    Files.host!()
    profile = profile!()

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
    Mix.shell().info("Downloading and checking macOS #{profile["macos"]["version"]} IPSW")

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
    Mix.shell().info("Building and cold-booting the blank base")
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

    major = profile["macos"]["version"] |> String.split(".") |> hd()
    selected_spec = Path.join(project, "ci/fixtures/system/bases/macos#{major}.json")

    Command.run!(
      "mix",
      [
        "nerves.macos.base",
        "lock",
        "--macos",
        major,
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

    File.cp!(Path.join(project, "mix.lock"), Path.join(project, "ci/fixtures/native/mix.lock"))

    env = %{
      "MIX_TARGET" => "macos" <> major,
      "NERVES_ARTIFACTS_DIR" => Path.join(root, "artifacts"),
      "NERVES_MACOS_OTP_ROOT" => Path.join(otp, "usr/local/lib/erlang")
    }

    hello = Path.join(project, "ci/fixtures/native")

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

    Mix.shell().info(
      "macOS #{major} passed a clean base build, Nerves firmware build and two cold boots"
    )
  end

  defp profile! do
    major = System.get_env("MACOS_MAJOR", "15")
    unless major in ~w(15 26 27), do: raise("Select macOS 15, 26 or 27")
    "ci/macos#{major}.json" |> File.read!() |> Jason.decode!()
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

  defp verified_run, do: System.get_env("VERIFIED_RUN", "")

  defp run_id do
    value = System.fetch_env!("GITHUB_RUN_ID") <> "-" <> System.fetch_env!("GITHUB_RUN_ATTEMPT")
    unless Regex.match?(~r/\A\d+-\d+\z/, value), do: raise("Expected a GitHub Actions run ID")
    value
  end
end

case System.argv() do
  [] ->
    BaseImageCI.run()

  ["check"] ->
    BaseImageCI.check()

  ["check-publication"] ->
    BaseImageCI.check_publication()

  ["export"] ->
    BaseImageCI.export()

  ["verify-publication"] ->
    BaseImageCI.verify_publication()

  ["restore"] ->
    BaseImageCI.restore()

  ["cleanup"] ->
    BaseImageCI.cleanup()

  _ ->
    raise "Usage: mix run ci/base-image.exs [check|check-publication|export|verify-publication|restore|cleanup]"
end
