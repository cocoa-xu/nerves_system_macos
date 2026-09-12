defmodule Nerves.System.MacOS.Config do
  @moduledoc false
  alias Nerves.System.MacOS.BaseSpec

  @enforce_keys [:base_image, :macos_version, :macos_build, :otp_root, :otp_version]
  defstruct [
    :base_image,
    :base_spec,
    :base_root,
    :macos_version,
    :macos_build,
    :otp_root,
    :otp_version,
    username: "admin",
    password: "admin"
  ]

  def new!(options, root) when is_list(options) do
    unless Keyword.keyword?(options),
      do: raise(ArgumentError, "Platform options must be a keyword list")

    allowed = [
      :base_image,
      :base_spec,
      :macos_version,
      :macos_build,
      :otp_root,
      :otp_version,
      :username,
      :password
    ]

    unknown = Keyword.keys(options) -- allowed
    if unknown != [], do: raise(ArgumentError, "Unknown platform options: #{inspect(unknown)}")

    {base_image, spec, base_root, version, build} = base!(options, root)
    username = if is_nil(options[:username]), do: "admin", else: options[:username]
    password = if is_nil(options[:password]), do: "admin", else: options[:password]

    config = %__MODULE__{
      base_image: base_image,
      base_spec: spec,
      base_root: base_root,
      macos_version: version,
      macos_build: build,
      otp_root: Path.expand(required!(options, :otp_root), root),
      otp_version: required!(options, :otp_version),
      username: username,
      password: password
    }

    unless Regex.match?(~r/\A\d+\.\d+(\.\d+)?\z/, config.macos_version),
      do: raise(ArgumentError, "macos_version must be an exact version")

    unless Regex.match?(~r/\A[A-Za-z0-9]+\z/, config.macos_build),
      do: raise(ArgumentError, "macos_build must be an Apple build identifier")

    unless Regex.match?(~r/\A\d+(\.\d+)+\z/, config.otp_version),
      do: raise(ArgumentError, "otp_version must be an exact version")

    unless is_binary(config.username) and
             Regex.match?(~r/\A[a-z_][a-z0-9_-]*\z/, config.username),
           do: raise(ArgumentError, "Invalid guest username")

    unless is_binary(config.password) and config.password != "",
      do: raise(ArgumentError, "Guest password must not be empty")

    config
  end

  def validate_package!(package) do
    if file = package.config[:platform_config][:base_spec] do
      path = Path.expand(file, package.path)
      inputs = Enum.map(package.config[:checksum] || [], &Path.expand(&1, package.path))

      unless path in inputs,
        do:
          raise(
            ArgumentError,
            "The base specification must be explicitly listed in the Nerves package checksum"
          )

      BaseSpec.read!(path)
    end
  end

  defp base!(options, root) do
    if file = options[:base_spec] do
      if Enum.any?([:base_image, :macos_version, :macos_build], &Keyword.has_key?(options, &1)),
        do: raise(ArgumentError, "base_spec replaces base_image, macos_version and macos_build")

      if options[:username] not in [nil, "admin"] or options[:password] not in [nil, "admin"],
        do:
          raise(ArgumentError, "Published base specifications use the admin development account")

      path = Path.expand(file, root)
      spec = BaseSpec.read!(path)
      {nil, spec, Path.dirname(path), spec["macos"]["version"], spec["macos"]["build"]}
    else
      {Path.expand(required!(options, :base_image), root), nil, nil,
       required!(options, :macos_version), required!(options, :macos_build)}
    end
  end

  defp required!(options, key) do
    case options[key] do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "Missing platform option: #{key}"
    end
  end
end
