defmodule Nerves.System.MacOS.BaseSpec do
  @moduledoc "The image version, macOS build and source recorded in a base specification."
  alias Nerves.System.MacOS.Files

  @files ~w(config.json disk.img nvram.bin)
  @profiles [
    %{major: 15, version: "15.6.1", build: "24G90", runtime_validation: "passed"},
    %{major: 26, version: "26.6.2", build: "25G83", runtime_validation: "passed"},
    %{major: 27, version: "27.0", build: "26A428", runtime_validation: "passed", channel: "rc"}
  ]

  def profiles, do: @profiles

  def profile!(major) do
    Enum.find(@profiles, &(&1.major == major)) ||
      raise ArgumentError, "Select macOS 15, 26 or 27"
  end

  def read!(path) do
    Files.regular!(path)
    path |> File.read!() |> Jason.decode!() |> validate!()
  end

  def validate!(spec) when is_map(spec) do
    keys!(spec, ~w(format image_version macos source))
    unless spec["format"] == 1, do: raise(ArgumentError, "Unsupported base specification")
    image_version!(string!(spec, "image_version"))
    os = spec["macos"]
    keys!(os, ~w(version build architecture))
    version = string!(os, "version")

    unless Regex.match?(~r/\A(?:15|26|27)\.\d+(?:\.\d+)?\z/, version),
      do: raise(ArgumentError, "An exact macOS 15, 26 or 27 version is required")

    unless Regex.match?(~r/\A[A-Za-z0-9]+\z/, string!(os, "build")),
      do: raise(ArgumentError, "An exact Apple build identifier is required")

    unless os["architecture"] == "arm64", do: raise(ArgumentError, "Only arm64 is supported")
    tag(spec)
    source!(spec["source"])
    spec
  end

  def validate!(_), do: raise(ArgumentError, "Expected a base specification object")

  def fingerprint(spec) do
    spec
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def major(spec),
    do: spec["macos"]["version"] |> String.split(".") |> hd() |> String.to_integer()

  def tag(spec) do
    tag = "#{spec["macos"]["version"]}-#{spec["macos"]["build"]}-v#{spec["image_version"]}"
    if byte_size(tag) > 128, do: raise(ArgumentError, "The image tag must not exceed 128 bytes")
    tag
  end

  def files, do: @files

  def image_version!(value) when is_binary(value) do
    case Version.parse(value) do
      {:ok, %Version{build: nil}} -> value
      _ -> raise ArgumentError, "image_version must be a semantic version without build metadata"
    end
  end

  def image_version!(_), do: raise(ArgumentError, "image_version must be a semantic version")

  def digest!(value) do
    unless is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value),
      do: raise(ArgumentError, "Expected a lowercase SHA-256 digest")

    value
  end

  def reference!(value) do
    case Regex.run(~r/\A([a-z0-9.-]+(?::\d+)?)\/([a-z0-9._\/-]+)@sha256:([a-f0-9]{64})\z/, value) do
      [_, host, repository, digest] ->
        if Enum.any?(String.split(repository, "/"), &(&1 in ["", ".", ".."])),
          do: raise(ArgumentError, "Invalid OCI repository")

        {host, repository, digest}

      _ ->
        raise ArgumentError, "A digest-pinned OCI reference is required; tags are not accepted"
    end
  end

  defp source!(%{"type" => "local"} = source) do
    keys!(source, ~w(type path sha256))
    string!(source, "path")
    keys!(source["sha256"], @files)
    for file <- @files, do: digest!(source["sha256"][file])
  end

  defp source!(%{"type" => "prebuilt"} = source) do
    keys!(source, ~w(type reference insecure))
    {host, _, _} = reference!(string!(source, "reference"))
    insecure = Map.get(source, "insecure", false)
    unless is_boolean(insecure), do: raise(ArgumentError, "insecure must be a boolean")

    if insecure and not Regex.match?(~r/\A127\.0\.0\.1:\d+\z/, host),
      do: raise(ArgumentError, "Plain HTTP is limited to loopback registry tests")
  end

  defp source!(%{"type" => "build"} = source) do
    keys!(source, ~w(type executable sha256 repository revision arguments timeout_seconds))
    for key <- ~w(executable repository), do: string!(source, key)
    digest!(source["sha256"])

    unless Regex.match?(~r/\A[0-9a-f]{40}\z/, string!(source, "revision")),
      do: raise(ArgumentError, "The builder checkout must be pinned to a full Git revision")

    args = source["arguments"]

    unless is_list(args) and Enum.all?(args, &is_binary/1) and "{vm}" in args,
      do: raise(ArgumentError, "Builder arguments must contain a separate {vm} argument")

    timeout = Map.get(source, "timeout_seconds", 3600)

    unless is_integer(timeout) and timeout in 1..7200,
      do: raise(ArgumentError, "Builder timeout must be between 1 and 7200 seconds")
  end

  defp source!(_), do: raise(ArgumentError, "Select an explicit local, prebuilt or build source")

  defp keys!(value, allowed) when is_map(value) do
    unknown = Map.keys(value) -- allowed
    if unknown != [], do: raise(ArgumentError, "Unknown base fields: #{inspect(unknown)}")
  end

  defp keys!(_, _), do: raise(ArgumentError, "Expected an object in the base specification")

  defp string!(map, key) do
    case map[key] do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _ -> raise ArgumentError, "Missing base field: #{key}"
    end
  end

  defp canonical(value) when is_map(value),
    do: value |> Enum.sort() |> Enum.map(fn {key, item} -> {key, canonical(item)} end)

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
