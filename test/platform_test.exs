defmodule Nerves.System.MacOS.PlatformTest do
  use ExUnit.Case, async: true
  alias Nerves.System.MacOS.{Artifact, Command, Config, Files, VM}

  setup do
    directory = Path.join(System.tmp_dir!(), "nerves-macos-test-" <> Files.unique())
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "requires explicit base, OS identity, and runtime" do
    options = [
      base_image: "base",
      macos_version: "26.6.2",
      macos_build: "25G83",
      otp_root: "otp",
      otp_version: "29.0.2"
    ]

    config = Config.new!(options, "/tmp")
    assert config.base_image == "/tmp/base"
    assert config.username == "admin"

    for key <- Keyword.keys(options) do
      assert_raise ArgumentError, fn -> Config.new!(Keyword.delete(options, key), "/tmp") end
    end

    assert_raise ArgumentError, fn -> Config.new!(options ++ [typo: true], "/tmp") end

    assert_raise ArgumentError, fn ->
      Config.new!(Keyword.put(options, :macos_version, "latest"), "/tmp")
    end
  end

  test "passes arguments without shell expansion" do
    assert Command.run!("/usr/bin/printf", ["%s", "$(exit 99); `false`"]) == "$(exit 99); `false`"
  end

  test "reports errors and bounds child process lifetime", %{directory: directory} do
    assert_raise RuntimeError, ~r/status 7/, fn ->
      Command.run!("/bin/sh", ["-c", "echo failed; exit 7"])
    end

    marker = Path.join(directory, "child-finished")

    assert_raise RuntimeError, ~r/deadline/, fn ->
      Command.run!("/bin/sh", ["-c", "(sleep 1; touch \"$1\") & wait", "sh", marker],
        timeout: 100
      )
    end

    Process.sleep(1_100)
    refute File.exists?(marker)
  end

  test "refuses to replace files or clean unmarked directories", %{directory: directory} do
    assert_raise RuntimeError, ~r/replace/, fn -> Files.absent!(directory) end
    assert_raise RuntimeError, fn -> Artifact.clean(directory) end
    assert File.dir?(directory)
    Files.write_json(Path.join(directory, "nerves-macos.json"), %{format: 1, platform: "macos"})
    link = directory <> "-link"
    File.ln_s!(directory, link)
    on_exit(fn -> File.rm(link) end)
    assert_raise RuntimeError, ~r/symlink/, fn -> Artifact.clean(link) end
    assert File.dir?(directory)
  end

  test "rejects a VM with a symlink disk", %{directory: directory} do
    File.write!(Path.join(directory, "config.json"), "{}")
    File.ln_s!("config.json", Path.join(directory, "disk.img"))
    assert_raise RuntimeError, ~r/regular file/, fn -> VM.validate!(directory) end
  end

  test "rejects foreign native files and escaping runtime symlinks", %{directory: directory} do
    path = Path.join(directory, "foreign.so")
    File.write!(path, <<127, 69, 76, 70, 0, 0, 0, 0>>)

    assert_raise RuntimeError, ~r/ELF file/, fn ->
      Nerves.System.MacOS.Runtime.validate!(directory)
    end

    File.rm!(path)
    File.ln_s!("/etc/passwd", path)

    assert_raise RuntimeError, ~r/Symlink escapes/, fn ->
      Nerves.System.MacOS.Runtime.validate!(directory)
    end
  end

  test "archives preserve sparse disk allocation", %{directory: directory} do
    source = Path.join(directory, "source")
    File.mkdir_p!(source)
    Files.write_json(Path.join(source, "nerves-macos.json"), %{format: 1, platform: "macos"})

    File.open!(Path.join(source, "disk.img"), [:write], fn file ->
      :file.position(file, 64 * 1024 * 1024)
      IO.binwrite(file, "end")
    end)

    archive = Path.join(directory, "system.tar.gz")
    Artifact.archive(source, archive)
    assert File.stat!(archive).size < 10_000
    output = Path.join(directory, "output")
    File.mkdir_p!(output)
    Command.run!("gtar", ["-xzf", archive, "-C", output])
    assert File.stat!(Path.join(output, "disk.img")).size == 64 * 1024 * 1024 + 3
    assert_raise RuntimeError, ~r/replace/, fn -> Artifact.archive(source, archive) end
  end
end
