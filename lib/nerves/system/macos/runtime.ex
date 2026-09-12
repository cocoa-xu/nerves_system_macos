defmodule Nerves.System.MacOS.Runtime do
  @moduledoc false
  alias Nerves.System.MacOS.{Command, Files}

  def stage(source, destination, expected_version, macos_version \\ nil) do
    erts = exactly_one!(Path.join(source, "erts-*"), "ERTS directory")
    version_file = exactly_one!(Path.join(source, "releases/*/OTP_VERSION"), "OTP_VERSION file")
    unless File.dir?(erts), do: raise("Runtime ERTS path is not a directory")
    Files.regular!(version_file)
    otp_version = version_file |> File.read!() |> String.trim()

    unless otp_version == expected_version,
      do: raise("OTP version does not match the system configuration")

    unless hd(String.split(otp_version, ".")) == System.otp_release(),
      do: raise("The system OTP major version must match the host compiler")

    Files.clone(source, destination)
    validate!(destination, macos_version)

    openssl =
      Command.run!(
        Path.join(destination, "bin/erl"),
        [
          "+S",
          "2:2",
          "-noshell",
          "-eval",
          "{ok, _} = application:ensure_all_started(crypto), 32 = byte_size(crypto:strong_rand_bytes(32)), [{_, _, V}] = crypto:info_lib(), io:format(\"~s\", [V]), halt()."
        ],
        env: %{"ERL_ROOTDIR" => destination}
      )

    %{
      otp_version: otp_version,
      openssl: String.trim(openssl),
      erts_version: String.replace_prefix(Path.basename(erts), "erts-", "")
    }
  end

  def validate!(path, macos_version \\ nil) do
    args =
      [Files.priv("scripts/validate-native.py"), path] ++
        if(macos_version, do: [macos_version], else: [])

    Command.run!("python3", args, timeout: 300_000)
  end

  defp exactly_one!(pattern, description) do
    case Path.wildcard(pattern) do
      [path] -> path
      matches -> raise "Runtime must contain exactly one #{description}, found #{length(matches)}"
    end
  end
end
