defmodule Nerves.System.MacOS.BaseSpecTest do
  use ExUnit.Case, async: true
  alias Nerves.System.MacOS.{BaseImage, BaseSpec, Command, Config, Files, Runtime}

  setup do
    directory = Path.join(System.tmp_dir!(), "nerves-base-test-" <> Files.unique())
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  defp spec(major \\ 26) do
    profile = BaseSpec.profile!(major)

    %{
      "format" => 1,
      "macos" => %{
        "version" => profile.version,
        "build" => profile.build,
        "architecture" => "arm64"
      },
      "source" => %{
        "type" => "prebuilt",
        "reference" => "ghcr.io/example/macos@sha256:" <> String.duplicate("a", 64)
      }
    }
  end

  test "selects exact identities for all three majors without claiming runtime validation" do
    assert Enum.map(BaseSpec.profiles(), & &1.major) == [15, 26, 27]
    for major <- [15, 26, 27], do: assert(BaseSpec.validate!(spec(major)))
    assert BaseSpec.profile!(15).runtime_validation == "pending"
    assert BaseSpec.profile!(26).runtime_validation == "passed"
    assert BaseSpec.profile!(27).channel == "rc"
    assert_raise ArgumentError, fn -> BaseSpec.profile!(16) end
  end

  test "rejects moving references, unknown options and mismatched architecture" do
    assert_raise ArgumentError, ~r/tags/, fn ->
      BaseSpec.validate!(put_in(spec(), ["source", "reference"], "ghcr.io/example/macos:latest"))
    end

    assert_raise ArgumentError, ~r/Unknown/, fn ->
      BaseSpec.validate!(Map.put(spec(), "fallback", true))
    end

    assert_raise ArgumentError, ~r/arm64/, fn ->
      BaseSpec.validate!(put_in(spec(), ["macos", "architecture"], "x86_64"))
    end

    assert_raise ArgumentError, ~r/exact/, fn ->
      BaseSpec.validate!(put_in(spec(), ["macos", "version"], "26"))
    end

    assert_raise ArgumentError, ~r/loopback/, fn ->
      BaseSpec.validate!(put_in(spec(), ["source", "insecure"], true))
    end
  end

  test "separates source trust choices and OS identities in the fingerprint" do
    first = spec()

    local = %{
      first
      | "source" => %{
          "type" => "local",
          "path" => "base",
          "sha256" => Map.new(BaseSpec.files(), &{&1, String.duplicate("a", 64)})
        }
    }

    BaseSpec.validate!(local)
    assert BaseSpec.fingerprint(first) != BaseSpec.fingerprint(local)
    assert BaseSpec.fingerprint(first) != BaseSpec.fingerprint(spec(15))

    assert BaseSpec.fingerprint(first) ==
             BaseSpec.fingerprint(Jason.decode!(Jason.encode!(first)))
  end

  test "base selection participates in Nerves checksums and build paths", %{directory: root} do
    file = Path.join(root, "base.json")
    Files.write_json(file, spec())

    package = %Nerves.Package{
      app: :base_test,
      version: "1.0.0",
      path: root,
      type: :system,
      platform: Nerves.System.MacOS,
      config: [platform_config: [base_spec: "base.json"]]
    }

    assert_raise ArgumentError, ~r/checksum/, fn -> Config.validate_package!(package) end
    package = %{package | config: package.config ++ [checksum: ["base.json"]]}
    first = Nerves.System.MacOS.build_path_link(package)
    first_checksum = Nerves.Artifact.checksum(package)
    Files.write_json(file, spec(15))
    assert Nerves.Artifact.checksum(package) != first_checksum
    assert Nerves.System.MacOS.build_path_link(package) != first
    config = Config.new!([base_spec: "base.json", otp_root: "otp", otp_version: "29.0.2"], root)
    assert config.macos_version == "15.6.1"
    assert config.base_image == nil

    assert_raise ArgumentError, ~r/replaces/, fn ->
      Config.new!([base_spec: "base.json", base_image: "old"], root)
    end
  end

  test "prebuilt specifications cannot embed registry credentials" do
    assert_raise ArgumentError, ~r/Unknown/, fn ->
      BaseSpec.validate!(put_in(spec(), ["source", "password"], "credential"))
    end
  end

  test "rejects changed pinned content before it can be used", %{directory: root} do
    path = Path.join(root, "input")
    File.write!(path, "original")
    digest = Files.sha256(path)
    assert BaseImage.verify_digest!(path, digest) == nil
    File.write!(path, "changed")

    assert_raise RuntimeError, ~r/SHA-256 mismatch/, fn ->
      BaseImage.verify_digest!(path, digest)
    end
  end

  test "requires a pinned executable, checkout and bounded builder command" do
    source = %{
      "type" => "build",
      "executable" => "builder",
      "sha256" => String.duplicate("a", 64),
      "repository" => "source",
      "revision" => String.duplicate("b", 40),
      "arguments" => ["build", "{vm}"]
    }

    assert BaseSpec.validate!(%{spec() | "source" => source})

    for invalid <- [
          Map.put(source, "arguments", ["build"]),
          Map.put(source, "revision", "main"),
          Map.put(source, "timeout_seconds", 0),
          Map.delete(source, "sha256")
        ] do
      assert_raise ArgumentError, fn -> BaseSpec.validate!(%{spec() | "source" => invalid}) end
    end
  end

  test "rejects a native extension requiring a newer guest OS", %{directory: root} do
    input = Path.join(root, "native.c")
    File.mkdir_p!(Path.join(root, "lib"))
    output = Path.join(root, "lib/native.so")
    File.ln_s!("lib/native.so", Path.join(root, "entry"))
    File.write!(input, "int example(void) { return 1; }\n")
    Command.run!("clang", ["-target", "arm64-apple-macos26.0", "-bundle", input, "-o", output])
    assert Runtime.validate!(root, "26.6.2") =~ "portable arm64"

    assert_raise RuntimeError, ~r/requires macOS 26.*newer than 15/, fn ->
      Runtime.validate!(root, "15.6.1")
    end
  end
end
