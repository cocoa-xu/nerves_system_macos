defmodule Nerves.System.MacOS.BaseAcquisitionTest do
  use ExUnit.Case, async: false
  alias Nerves.System.MacOS.{BaseImage, BaseSpec, Command, Files}

  setup do
    directory = Path.join(System.tmp_dir!(), "nerves-acquire-test-" <> Files.unique())
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  defp spec(source),
    do: %{
      "format" => 1,
      "macos" => %{"version" => "15.6.1", "build" => "24G90", "architecture" => "arm64"},
      "source" => source
    }

  test "pulls a real pinned OCI base through an auth challenge and removes its private cache", %{
    directory: root
  } do
    script = Path.expand("support/base_registry.py", __DIR__)
    registry = Task.async(fn -> Command.run!("python3", [script, root], timeout: 150_000) end)

    try do
      ready = Path.join(root, "ready.json")
      wait_for(ready, 250)
      reference = ready |> File.read!() |> Jason.decode!() |> Map.fetch!("reference")
      base = spec(%{"type" => "prebuilt", "reference" => reference, "insecure" => true})

      BaseImage.with_source(base, root, root, fn image ->
        assert File.stat!(Path.join(image, "disk.img")).size == 16 * 1024 * 1024
        assert File.read!(Path.join(image, "nvram.bin")) == "fixture"
      end)

      assert Path.wildcard(Path.join(root, "session-*")) == []
      requests = root |> Path.join("registry/requests.jsonl") |> File.read!()
      assert requests =~ "\"status\": 401"
      assert requests =~ "\"status\": 200"
      digest = :crypto.hash(:sha256, "fixture") |> Base.encode16(case: :lower)
      File.write!(Path.join(root, "registry/blobs/sha256:" <> digest), "altered")

      assert_raise RuntimeError, ~r/OCI.*SHA-256/, fn ->
        BaseImage.with_source(base, root, root, fn _ -> flunk("A corrupted blob was accepted") end)
      end

      assert Path.wildcard(Path.join(root, "session-*")) == []
    after
      File.touch!(Path.join(root, "stop"))
      Task.await(registry, 10_000)
    end
  end

  test "executes only a pinned local builder and cleans its private output", %{directory: root} do
    repository = Path.join(root, "builder")
    File.mkdir_p!(repository)
    executable = Path.join(repository, "build.sh")

    File.write!(executable, """
    #!/bin/sh
    set -eu
    target="$TART_HOME/vms/$1"
    mkdir -p "$target"
    printf '%s' '{"os":"darwin","arch":"arm64","hardwareModel":"YQ==","ecid":"YQ=="}' > "$target/config.json"
    printf fixture > "$target/disk.img"
    printf fixture > "$target/nvram.bin"
    """)

    File.chmod!(executable, 0o755)
    Command.run!("git", ["init", "--quiet", repository])
    Command.run!("git", ["add", "build.sh"], cd: repository)

    env = %{
      "GIT_AUTHOR_NAME" => "Cocoa",
      "GIT_AUTHOR_EMAIL" => "i@uwucocoa.moe",
      "GIT_COMMITTER_NAME" => "Cocoa",
      "GIT_COMMITTER_EMAIL" => "i@uwucocoa.moe"
    }

    Command.run!(
      "git",
      ["-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Add the builder fixture"],
      cd: repository,
      env: env
    )

    revision = Command.run!("git", ["rev-parse", "HEAD"], cd: repository) |> String.trim()

    source = %{
      "type" => "build",
      "executable" => executable,
      "sha256" => Files.sha256(executable),
      "repository" => repository,
      "revision" => revision,
      "arguments" => ["{vm}"]
    }

    base = spec(source) |> BaseSpec.validate!()

    BaseImage.with_source(base, root, root, fn image ->
      assert File.read!(Path.join(image, "disk.img")) == "fixture"
    end)

    assert Path.wildcard(Path.join(root, "session-*")) == []
    File.write!(executable, "\n", [:append])

    assert_raise RuntimeError, ~r/SHA-256 mismatch/, fn ->
      BaseImage.with_source(base, root, root, fn _ -> flunk() end)
    end

    assert Path.wildcard(Path.join(root, "session-*")) == []
    updated = put_in(base, ["source", "sha256"], Files.sha256(executable))

    assert_raise RuntimeError, ~r/status 1/, fn ->
      BaseImage.with_source(updated, root, root, fn _ -> flunk() end)
    end

    assert Path.wildcard(Path.join(root, "session-*")) == []
  end

  defp wait_for(path, attempts) when attempts > 0 do
    if not File.exists?(path) do
      Process.sleep(200)
      wait_for(path, attempts - 1)
    end
  end

  defp wait_for(_path, 0), do: flunk("The registry did not become ready within 50 seconds")
end
