defmodule Nerves.System.MacOS.Environment do
  @moduledoc false
  alias Nerves.System.MacOS.{Artifact, Command, Files}

  def activate(path) do
    Files.host!()
    metadata = Artifact.read!(path)

    unless hd(String.split(metadata["otp_version"], ".")) == System.otp_release(),
      do: raise("Host and system Erlang/OTP major versions differ")

    runtime = Path.join(path, "runtime")
    erts = Path.join(runtime, "erts-" <> metadata["erts_version"])
    unless File.dir?(erts), do: raise("System ERTS directory is missing")
    sdk = String.trim(Command.run!("xcrun", ["--sdk", "macosx", "--show-sdk-path"]))

    interface =
      case Path.wildcard(Path.join(runtime, "lib/erl_interface-*")) do
        [path] ->
          unless File.dir?(path), do: raise("System erl_interface path is not a directory")
          path

        _ ->
          raise "System runtime must contain exactly one erl_interface directory"
      end

    values = %{
      "NERVES_SYSTEM" => Path.expand(path),
      "NERVES_TOOLCHAIN" => sdk,
      "NERVES_SDK_SYSROOT" => sdk,
      "NERVES_SDK_IMAGES" => Path.join(path, "system.tart"),
      "ERTS_DIR" => erts,
      "ERL_LIB_DIR" => runtime,
      "ERL_SYSTEM_LIB_DIR" => Path.join(runtime, "lib"),
      "ERL_EI_INCLUDE_DIR" => Path.join(interface, "include"),
      "ERL_EI_LIBDIR" => Path.join(interface, "lib"),
      "CC" => "clang",
      "CXX" => "clang++",
      "AR" => "ar",
      "SDKROOT" => sdk,
      "MACOSX_DEPLOYMENT_TARGET" => metadata["macos_version"],
      "CROSSCOMPILE" => "",
      "TARGET_ARCH" => "aarch64",
      "TARGET_OS" => "darwin"
    }

    System.put_env(values)
    :ok
  end
end
