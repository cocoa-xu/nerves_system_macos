defmodule Nerves.System.MacOS.Config do
  @moduledoc false

  @enforce_keys [:base_image, :macos_version, :macos_build, :otp_root, :otp_version]
  defstruct [
    :base_image,
    :macos_version,
    :macos_build,
    :otp_root,
    :otp_version,
    username: "admin",
    password: "admin"
  ]

  def new!(options, root) when is_list(options) do
    allowed = [
      :base_image,
      :macos_version,
      :macos_build,
      :otp_root,
      :otp_version,
      :username,
      :password
    ]

    unknown = Keyword.keys(options) -- allowed
    if unknown != [], do: raise(ArgumentError, "Unknown platform options: #{inspect(unknown)}")

    config = %__MODULE__{
      base_image: Path.expand(required!(options, :base_image), root),
      macos_version: required!(options, :macos_version),
      macos_build: required!(options, :macos_build),
      otp_root: Path.expand(required!(options, :otp_root), root),
      otp_version: required!(options, :otp_version),
      username: options[:username] || "admin",
      password: options[:password] || "admin"
    }

    unless Regex.match?(~r/^\d+\.\d+(\.\d+)?$/, config.macos_version),
      do: raise(ArgumentError, "macos_version must be an exact version")

    unless Regex.match?(~r/^[A-Za-z0-9]+$/, config.macos_build),
      do: raise(ArgumentError, "macos_build must be an Apple build identifier")

    unless Regex.match?(~r/^\d+(\.\d+)+$/, config.otp_version),
      do: raise(ArgumentError, "otp_version must be an exact version")

    unless Regex.match?(~r/^[a-z_][a-z0-9_-]*$/, config.username),
      do: raise(ArgumentError, "Invalid guest username")

    unless is_binary(config.password) and config.password != "",
      do: raise(ArgumentError, "Guest password must not be empty")

    config
  end

  defp required!(options, key) do
    case options[key] do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "Missing platform option: #{key}"
    end
  end
end
