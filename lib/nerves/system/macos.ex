defmodule Nerves.System.MacOS do
  @moduledoc """
  Builds Nerves system artifacts for macOS guests on Apple silicon.

  System packages select this platform and `Nerves.Artifact.BuildRunners.Local`.
  Their `:platform_config` contains a stopped `:base_image` directory, an exact
  `:macos_version` and `:macos_build`, and a self-contained native `:otp_root`.
  """

  @behaviour Nerves.Package.Platform
  @behaviour Nerves.Artifact.BuildRunner

  alias Nerves.System.MacOS.{Artifact, Config, Environment}

  @impl true
  def bootstrap(_platform) do
    case System.get_env("NERVES_SYSTEM") do
      nil -> {:error, "NERVES_SYSTEM is not set"}
      path -> Environment.activate(path)
    end
  end

  @impl true
  def build(package, _toolchain, options) do
    protect(fn ->
      config = Config.new!(package.config[:platform_config] || [], package.path)
      path = build_path_link(package)
      Artifact.build(config, path, options)
      {:ok, path}
    end)
  end

  @impl true
  def build_path_link(package), do: Nerves.Artifact.build_path(package)

  @impl true
  def archive(package, _toolchain, options) do
    protect(fn ->
      destination =
        Path.join(
          options[:path] || File.cwd!(),
          Nerves.Artifact.download_name(package) <> ".tar.gz"
        )

      Artifact.archive(build_path_link(package), destination)
      {:ok, destination}
    end)
  end

  @impl true
  def clean(package) do
    protect(fn ->
      Artifact.clean(build_path_link(package))
      Nerves.Artifact.Cache.delete(package)
      :ok
    end)
  end

  defp protect(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
  end
end
